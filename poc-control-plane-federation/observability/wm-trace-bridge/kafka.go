package main

import (
	"context"
	"log"
	"strings"

	"github.com/twmb/franz-go/pkg/kgo"
)

// txnPublisher est la branche analytics du Y (ADR-070/073) : le JSON BRUT de
// chaque événement Transactional part vers Redpanda (topic stoa.txn.webmethods),
// où Data Prepper normalise/redacte vers OpenSearch txn-{tenant} — symétrique
// du kafka-logger APISIX. Interface pour rester testable sans broker.
type txnPublisher interface {
	Publish(raw []byte)
	Close()
}

type noopPublisher struct{}

func (noopPublisher) Publish([]byte) {}
func (noopPublisher) Close()         {}

type kafkaPublisher struct {
	client *kgo.Client
	topic  string
}

// newTxnPublisher construit le producteur Kafka, ou un no-op si brokers est
// vide (stack analytics non démarrée : le bridge reste 100 % fonctionnel côté
// traces). Best-effort assumé : un broker injoignable se voit dans les logs,
// ne bloque jamais la réponse au dispatcher du gateway.
func newTxnPublisher(brokers, topic string) (txnPublisher, error) {
	if brokers == "" {
		return noopPublisher{}, nil
	}
	client, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(brokers, ",")...),
		kgo.AllowAutoTopicCreation(),
		kgo.DefaultProduceTopic(topic),
	)
	if err != nil {
		return nil, err
	}
	return &kafkaPublisher{client: client, topic: topic}, nil
}

func (p *kafkaPublisher) Publish(raw []byte) {
	p.client.Produce(context.Background(), &kgo.Record{Value: raw}, func(r *kgo.Record, err error) {
		if err != nil {
			log.Printf("kafka publish %s: %v (event analytics perdu, traces non affectées)", p.topic, err)
		}
	})
}

func (p *kafkaPublisher) Close() {
	// Flush borné par le contexte du shutdown appelant via Close simple : kgo
	// attend l'envoi des messages bufferisés.
	p.client.Close()
}

// runSpanConsumer (HA, ADR-073 révision) : l'émission des spans est découplée
// de l'ingestion HTTP par le topic — groupe DISTINCT de data-prepper, chacun
// lit tout. Bridge redémarré ou otel-lgtm down : les events attendent dans
// Redpanda, aucune perte aval. At-least-once (auto-commit kgo) : un crash
// entre émission et commit peut dupliquer un span — assumé (PoC et cible :
// deux spans identiques valent mieux qu'un trou).
func runSpanConsumer(ctx context.Context, brokers, topic, group string, handle func([]byte)) error {
	client, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(brokers, ",")...),
		kgo.ConsumeTopics(topic),
		kgo.ConsumerGroup(group),
		// Premier boot du groupe : on part de la FIN (pas de replay de
		// l'historique → pas de spans dupliqués avec l'ancien mode direct).
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()),
	)
	if err != nil {
		return err
	}
	go func() {
		defer client.Close()
		for {
			fetches := client.PollFetches(ctx)
			if ctx.Err() != nil {
				return
			}
			fetches.EachError(func(t string, p int32, err error) {
				log.Printf("kafka consume %s[%d]: %v", t, p, err)
			})
			fetches.EachRecord(func(r *kgo.Record) { handle(r.Value) })
		}
	}()
	return nil
}
