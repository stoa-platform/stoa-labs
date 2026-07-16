package main

// userdeploy.go — chaîne A (ADR-077) branchée sur le flux A7 : au moment du
// promote-approve, le BFF détient le Bearer de l'APPROBATEUR ; il l'échange
// (token exchange standard RFC 8693, client confidentiel vault-exchange)
// contre un JWT court aud=vault + tenant, puis déclenche le job Jenkins
// stoa-user-deploy avec ce JWT dans le payload. Le job CI ne détient AUCUN
// credential propre : le token Vault qu'il obtient est NOMINATIF (entité =
// l'approbateur) et tenant-scopé.
//
// Opt-in par environnement — sans USER_DEPLOY_WEBHOOK_URL et un secret
// d'échangeur, UserDeploy est nil et le flux A7 est strictement inchangé.
// Le dispatch est asynchrone et n'affecte JAMAIS la réponse d'approve : le
// lien approbation → exchange est organisationnel (seul le BFF détient le
// secret de l'échangeur et n'échange qu'APRÈS les gates 4-yeux/ITSM), cf.
// ADR-077 §Limites (7).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// UserDeploy échange le jeton de l'approbateur et déclenche le job user-deploy.
type UserDeploy struct {
	TokenURL     string // endpoint token du realm Keycloak
	ClientID     string // échangeur confidentiel (vault-exchange)
	ClientSecret string
	Audience     string // audience cible de l'exchange (vault)
	WebhookURL   string // generic-webhook-trigger Jenkins (token inclus dans l'URL)
	HTTP         *http.Client
}

// NewUserDeployFromEnv construit le dispatcher si (et seulement si) le wiring
// est demandé : USER_DEPLOY_WEBHOOK_URL + VAULT_EXCHANGE_SECRET[_FILE].
// Le fichier 0600 est préféré (standard ADR-074 : les secrets ne vivent ni en
// argv ni, idéalement, en env).
func NewUserDeployFromEnv(kcBase, realm string) *UserDeploy {
	hook := os.Getenv("USER_DEPLOY_WEBHOOK_URL")
	secret := os.Getenv("VAULT_EXCHANGE_SECRET")
	if f := os.Getenv("VAULT_EXCHANGE_SECRET_FILE"); f != "" {
		// Config EXPLICITE = contrat : un fichier illisible doit arrêter le boot
		// (fail-fast bruyant), pas désactiver le canal en silence ni retomber
		// en douce sur le secret env (une rotation via fichier ne prendrait
		// jamais effet).
		b, err := os.ReadFile(f)
		if err != nil {
			log.Fatalf("governance-api: VAULT_EXCHANGE_SECRET_FILE=%s illisible: %v", f, err)
		}
		secret = strings.TrimSpace(string(b))
	}
	if hook == "" || secret == "" {
		return nil
	}
	return &UserDeploy{
		TokenURL:     strings.TrimRight(kcBase, "/") + "/realms/" + realm + "/protocol/openid-connect/token",
		ClientID:     envOr("VAULT_EXCHANGE_CLIENT_ID", "vault-exchange"),
		ClientSecret: secret,
		Audience:     envOr("VAULT_EXCHANGE_AUDIENCE", "vault"),
		WebhookURL:   hook,
		HTTP:         &http.Client{Timeout: 15 * time.Second},
	}
}

// Exchange convertit le Bearer de l'utilisateur (adressé aud=vault-exchange)
// en JWT court aud=vault (RFC 8693). Les messages d'erreur ne portent JAMAIS
// de jeton — seulement le code d'erreur Keycloak.
func (u *UserDeploy) Exchange(ctx context.Context, subjectToken string) (string, error) {
	form := url.Values{
		"grant_type":         {"urn:ietf:params:oauth:grant-type:token-exchange"},
		"client_id":          {u.ClientID},
		"client_secret":      {u.ClientSecret},
		"subject_token":      {subjectToken},
		"subject_token_type": {"urn:ietf:params:oauth:token-type:access_token"},
		"audience":           {u.Audience},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := u.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("exchange: %w", stripURLError(err))
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("exchange: lecture réponse: %w", err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
		ErrorDesc   string `json:"error_description"`
	}
	if err := json.Unmarshal(raw, &tok); err != nil {
		return "", fmt.Errorf("exchange: réponse HTTP %d non-JSON", resp.StatusCode)
	}
	if tok.AccessToken == "" {
		return "", fmt.Errorf("exchange refusé (HTTP %d): %s %s", resp.StatusCode, tok.Error, tok.ErrorDesc)
	}
	return tok.AccessToken, nil
}

// Dispatch échange le jeton puis déclenche le webhook Jenkins. hint est une
// donnée d'affichage non-secrète (promotion, approbateur).
func (u *UserDeploy) Dispatch(ctx context.Context, subjectToken, hint string) error {
	jwt, err := u.Exchange(ctx, subjectToken)
	if err != nil {
		return err
	}
	body, err := json.Marshal(map[string]string{"vault_jwt": jwt, "hint": hint})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.WebhookURL, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := u.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("webhook: %w", stripURLError(err))
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook: HTTP %d", resp.StatusCode)
	}
	return nil
}

// stripURLError retire l'URL d'une *url.Error : le format par défaut de Go
// (`Post "http://…?token=…": dial …`) inclut la query string, donc le token du
// generic-webhook-trigger — qui partirait dans les logs via log.Printf. On ne
// garde que l'opération et l'erreur transport nue.
func stripURLError(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return fmt.Errorf("%s: %w", ue.Op, ue.Err)
	}
	return err
}
