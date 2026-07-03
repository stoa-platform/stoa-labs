package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// Event est le sous-ensemble utile des événements que webMethods API Gateway
// 10.15 POSTe à une custom destination « External endpoint » (un objet JSON
// par POST, vérifié in-situ 2026-06-12 sur apigateway-trial:10.15).
// Schéma officiel : APIGatewayTransactionalEvent.json (repo SoftwareAG).
// Champs numériques : null possible (gatewayTime=null observé au 1er appel
// après boot) — encoding/json laisse alors le zero value, c'est voulu.
// float64 et non int64 : un fixpack qui sérialiserait 1835.0 au lieu de 1835
// perdrait sinon TOUS les événements (epoch ms < 2^53, exact en float64).
type Event struct {
	EventType         string         `json:"eventType"` // "Transactional" | "PolicyViolation" | "Error" | ...
	APIName           string         `json:"apiName"`
	APIVersion        string         `json:"apiVersion"`
	OperationName     string         `json:"operationName"`
	HTTPMethod        string         `json:"httpMethod"`
	NativeHTTPMethod  string         `json:"nativeHttpMethod"`
	NativeURL         string         `json:"nativeURL"`
	Status            string         `json:"status"` // "SUCCESS" | "FAILURE"
	ResponseCode      string         `json:"responseCode"`
	TotalTime         float64        `json:"totalTime"`    // ms
	GatewayTime       float64        `json:"gatewayTime"`  // ms (peut être null)
	ProviderTime      float64        `json:"providerTime"` // ms (peut être null)
	CreationDate      float64        `json:"creationDate"` // epoch ms
	CorrelationID     string         `json:"correlationID"`
	SessionID         string         `json:"sessionId"`
	ApplicationName   string         `json:"applicationName"`
	ApplicationIP     string         `json:"applicationIp"`
	SourceGatewayNode string         `json:"sourceGatewayNode"`
	RequestHeaders    map[string]any `json:"requestHeaders"`
	ExternalCalls     []ExternalCall `json:"externalCalls"`
	// Spécifiques PolicyViolation.
	AlertDesc   string `json:"alertDesc"`
	AlertSource string `json:"alertSource"`
	AlertType   string `json:"alertType"`
}

// ExternalCall donne la fenêtre EXACTE des appels sortants (dont l'appel au
// service natif) — observé in-situ, absent de la doc du schéma.
type ExternalCall struct {
	ExternalCallType string  `json:"externalCallType"` // "NATIVE_SERVICE_CALL" | ...
	ExternalURL      string  `json:"externalURL"`
	CallStartTime    float64 `json:"callStartTime"` // epoch ms
	CallEndTime      float64 `json:"callEndTime"`   // epoch ms
	ResponseCode     string  `json:"responseCode"`
}

// parseEvents accepte les trois formes plausibles du payload (objet seul —
// la forme observée —, tableau, ou enveloppe {"events":[...]}) pour rester
// robuste aux variations de version/fixpack. Le JSON BRUT de chaque événement
// est retourné aligné sur le slice d'Events : c'est lui qui part vers Redpanda
// (branche analytics du Y, ADR-070/073) — le bridge ne transforme pas, Data
// Prepper est l'autorité de normalisation/redaction.
func parseEvents(body []byte) ([]Event, [][]byte, error) {
	body = bytes.TrimSpace(body)
	if len(body) == 0 {
		return nil, nil, fmt.Errorf("empty body")
	}
	decodeRaws := func(raws []json.RawMessage) ([]Event, [][]byte, error) {
		evs := make([]Event, len(raws))
		bs := make([][]byte, len(raws))
		for i, r := range raws {
			if err := json.Unmarshal(r, &evs[i]); err != nil {
				return nil, nil, err
			}
			bs[i] = []byte(r)
		}
		return evs, bs, nil
	}
	switch body[0] {
	case '[':
		var raws []json.RawMessage
		if err := json.Unmarshal(body, &raws); err != nil {
			return nil, nil, err
		}
		return decodeRaws(raws)
	case '{':
		var ev Event
		if err := json.Unmarshal(body, &ev); err != nil {
			return nil, nil, err
		}
		if ev.EventType != "" || ev.APIName != "" {
			return []Event{ev}, [][]byte{body}, nil
		}
		var env struct {
			Events []json.RawMessage `json:"events"`
		}
		if err := json.Unmarshal(body, &env); err == nil && len(env.Events) > 0 {
			return decodeRaws(env.Events)
		}
		// Objet sans eventType/apiName ({}, ping de test de l'UI…) : erreur de
		// parse plutôt qu'un span poubelle « CALL / » dans Tempo.
		return nil, nil, fmt.Errorf("object without eventType/apiName (%d bytes)", len(body))
	default:
		return nil, nil, fmt.Errorf("unexpected payload start %q", body[0])
	}
}

// headerValue retourne la valeur d'un header indépendamment de la casse des
// clés (le gateway canonise différemment selon le chemin client/natif).
func headerValue(h map[string]any, name string) string {
	for k, v := range h {
		if !strings.EqualFold(k, name) {
			continue
		}
		switch t := v.(type) {
		case string:
			return t
		case []any:
			if len(t) > 0 {
				if s, ok := t[0].(string); ok {
					return s
				}
			}
		}
	}
	return ""
}

// remoteParent extrait le contexte de trace amont (W3C traceparent prioritaire,
// sinon B3) depuis les headers stockés par Log Invocation. On NE recopie aucun
// header dans les spans : on ne fait que LIRE le contexte de corrélation
// (capture model : métadonnées seules, jamais Authorization/cookies/payloads).
func remoteParent(h map[string]any) (trace.SpanContext, bool) {
	if tp := headerValue(h, "traceparent"); tp != "" {
		parts := strings.Split(tp, "-")
		if len(parts) >= 4 {
			tid, errT := trace.TraceIDFromHex(parts[1])
			sid, errS := trace.SpanIDFromHex(parts[2])
			if errT == nil && errS == nil {
				return trace.NewSpanContext(trace.SpanContextConfig{
					TraceID:    tid,
					SpanID:     sid,
					TraceFlags: trace.FlagsSampled,
					Remote:     true,
				}), true
			}
		}
	}
	b3t := headerValue(h, "x-b3-traceid")
	if b3t == "" {
		return trace.SpanContext{}, false
	}
	if len(b3t) == 16 {
		b3t = strings.Repeat("0", 16) + b3t
	}
	tid, err := trace.TraceIDFromHex(b3t)
	if err != nil {
		return trace.SpanContext{}, false
	}
	cfg := trace.SpanContextConfig{TraceID: tid, TraceFlags: trace.FlagsSampled, Remote: true}
	if sid, err := trace.SpanIDFromHex(headerValue(h, "x-b3-spanid")); err == nil {
		cfg.SpanID = sid
	}
	return trace.NewSpanContext(cfg), cfg.SpanID.IsValid()
}

func (ev Event) spanName() string {
	op := ev.OperationName
	if op == "" {
		op = "/"
	}
	return strings.ToUpper(nonEmpty(ev.HTTPMethod, "CALL")) + " " + ev.APIName + op
}

func (ev Event) isFailure() bool {
	if ev.EventType == "PolicyViolation" || ev.EventType == "Error" {
		return true
	}
	if ev.Status != "" && !strings.EqualFold(ev.Status, "SUCCESS") {
		return true
	}
	if code, err := strconv.Atoi(ev.ResponseCode); err == nil && code >= 400 {
		return true
	}
	return false
}

func (ev Event) attributes() []attribute.KeyValue {
	attrs := []attribute.KeyValue{
		attribute.String("wm.event_type", ev.EventType),
		attribute.String("wm.api.name", ev.APIName),
		attribute.String("wm.api.version", ev.APIVersion),
	}
	if ev.HTTPMethod != "" {
		attrs = append(attrs, attribute.String("http.request.method", strings.ToUpper(ev.HTTPMethod)))
	}
	if ev.OperationName != "" {
		attrs = append(attrs, attribute.String("url.path", ev.OperationName))
	}
	if code, err := strconv.Atoi(ev.ResponseCode); err == nil {
		attrs = append(attrs, attribute.Int("http.response.status_code", code))
	}
	if ev.ApplicationName != "" {
		attrs = append(attrs, attribute.String("wm.application", ev.ApplicationName))
	}
	if ev.CorrelationID != "" {
		attrs = append(attrs, attribute.String("wm.correlation_id", ev.CorrelationID))
	}
	if ev.SourceGatewayNode != "" {
		attrs = append(attrs, attribute.String("wm.gateway_node", ev.SourceGatewayNode))
	}
	if ev.AlertDesc != "" {
		attrs = append(attrs, attribute.String("wm.alert.description", ev.AlertDesc))
	}
	if ev.AlertType != "" {
		attrs = append(attrs, attribute.String("wm.alert.type", ev.AlertType))
	}
	return attrs
}

// nativeWindow retourne la fenêtre temporelle de l'appel natif : exacte si
// l'événement porte un externalCalls NATIVE_SERVICE_CALL (observé in-situ),
// sinon approximée en fin de fenêtre gateway via providerTime (repli pour
// les versions/fixpacks qui n'émettraient pas externalCalls).
func (ev Event) nativeWindow(start time.Time, total time.Duration) (time.Time, time.Time, bool) {
	for _, c := range ev.ExternalCalls {
		if c.ExternalCallType == "NATIVE_SERVICE_CALL" && c.CallStartTime > 0 && c.CallEndTime >= c.CallStartTime {
			return time.UnixMilli(int64(c.CallStartTime)), time.UnixMilli(int64(c.CallEndTime)), true
		}
	}
	if ev.ProviderTime <= 0 {
		return time.Time{}, time.Time{}, false
	}
	provider := time.Duration(ev.ProviderTime) * time.Millisecond
	if provider > total {
		provider = total
	}
	nStart := start.Add(total - provider)
	return nStart, nStart.Add(provider), true
}

// emit synthétise les spans OTel d'un événement : un span SERVER pour la
// traversée du gateway et, si un appel natif a eu lieu (Transactional), un
// span CLIENT enfant pour le backend. Les timestamps sont reconstruits depuis
// l'événement (les events arrivent en différé, on horodate au moment de la
// transaction, pas de la réception).
func emit(tracer trace.Tracer, ev Event) {
	start := time.UnixMilli(int64(ev.CreationDate))
	if ev.CreationDate == 0 {
		start = time.Now()
	}
	total := time.Duration(ev.TotalTime) * time.Millisecond
	if total <= 0 {
		total = time.Millisecond
	}

	ctx := contextBackground()
	if parent, ok := remoteParent(ev.RequestHeaders); ok {
		ctx = trace.ContextWithRemoteSpanContext(ctx, parent)
	}

	ctx, root := tracer.Start(ctx, ev.spanName(),
		trace.WithSpanKind(trace.SpanKindServer),
		trace.WithTimestamp(start),
		trace.WithAttributes(ev.attributes()...),
	)
	if ev.isFailure() {
		root.SetStatus(codes.Error, nonEmpty(ev.AlertDesc, "HTTP "+ev.ResponseCode))
	} else {
		root.SetStatus(codes.Ok, "")
	}

	if ev.EventType == "Transactional" && ev.NativeURL != "" {
		if nStart, nEnd, ok := ev.nativeWindow(start, total); ok {
			_, native := tracer.Start(ctx, "native "+nonEmpty(strings.ToUpper(ev.NativeHTTPMethod), "CALL"),
				trace.WithSpanKind(trace.SpanKindClient),
				trace.WithTimestamp(nStart),
				trace.WithAttributes(
					attribute.String("url.full", ev.NativeURL),
					attribute.String("http.request.method", nonEmpty(strings.ToUpper(ev.NativeHTTPMethod), "")),
				),
			)
			native.End(trace.WithTimestamp(nEnd))
		}
	}

	root.End(trace.WithTimestamp(start.Add(total)))
}

func nonEmpty(v, def string) string {
	if v != "" {
		return v
	}
	return def
}
