package main

import (
	"encoding/json"
	"os"
	"testing"
)

func TestParsePVHitsExtractsSourcesAndCursor(t *testing.T) {
	pv, err := os.ReadFile("testdata/policyviolation.json")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	esResp := map[string]any{
		"hits": map[string]any{
			"hits": []any{
				map[string]any{"_source": json.RawMessage(pv)},
				map[string]any{"_source": json.RawMessage(`{"no":"creationDate"}`)}, // ignoré
			},
		},
	}
	body, _ := json.Marshal(esResp)

	raws, cursor, err := parsePVHits(body)
	if err != nil {
		t.Fatalf("parsePVHits: %v", err)
	}
	if len(raws) != 1 {
		t.Fatalf("want 1 hit retenu (celui avec creationDate), got %d", len(raws))
	}
	// Le _source brut doit repasser tel quel dans le chemin commun des events.
	evs, _, err := parseEvents(raws[0])
	if err != nil || len(evs) != 1 || evs[0].EventType != "PolicyViolation" {
		t.Fatalf("le hit doit rester un event PolicyViolation parsable: %v %+v", err, evs)
	}
	if cursor != int64(evs[0].CreationDate) {
		t.Errorf("cursor = %d, want creationDate %v", cursor, evs[0].CreationDate)
	}

	// Réponse vide : pas d'erreur, pas d'avance de curseur.
	raws, cursor, err = parsePVHits([]byte(`{"hits":{"hits":[]}}`))
	if err != nil || len(raws) != 0 || cursor != 0 {
		t.Errorf("empty: %v / %d / %d", err, len(raws), cursor)
	}
}

func TestLastEventStore(t *testing.T) {
	var l lastEvent
	if raw, _ := l.Get(); raw != nil {
		t.Error("empty store must return nil")
	}
	l.Set([]byte(`{"a":1}`))
	raw, at := l.Get()
	if string(raw) != `{"a":1}` || at.IsZero() {
		t.Errorf("got %q at %v", raw, at)
	}
}
