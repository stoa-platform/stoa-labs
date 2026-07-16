package main

import (
	"context"
	"log"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
)

// txnPublisher est la branche analytics : un record JSON plat au schéma
// stoa.txn part vers Redpanda (topic stoa.txn.wso2), où Data Prepper
// normalise/redacte vers OpenSearch txn-{tenant} — symétrique du kafka-logger
// APISIX et du wm-trace-bridge. Interface pour rester testable sans broker.
// (Copie fidèle de wm-trace-bridge/kafka.go : même contrat, même best-effort.)
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
// vide (stack analytics non démarrée : le tap reste 100 % fonctionnel côté
// forward des traces). Best-effort assumé : un broker injoignable se voit dans
// les logs, ne bloque jamais le forward OTLP vers Tempo.
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
	p.client.Produce(context.Background(), &kgo.Record{Value: raw}, func(_ *kgo.Record, err error) {
		if err != nil {
			log.Printf("kafka publish %s: %v (record analytics perdu, traces non affectées)", p.topic, err)
		}
	})
}

func (p *kafkaPublisher) Close() {
	// Flush DRAINE les produces en vol AVANT Close : kgo.Close() annule le
	// contexte interne et fait ÉCHOUER les envois bufferisés (ne draine PAS),
	// donc sans ce Flush les derniers records (justement ceux que GracefulStop
	// vient de drainer côté gRPC) seraient perdus au shutdown. Best-effort :
	// borné à 5 s pour ne pas bloquer l'arrêt indéfiniment.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.client.Flush(ctx); err != nil {
		log.Printf("kafka flush au shutdown: %v (derniers records best-effort)", err)
	}
	p.client.Close()
}
