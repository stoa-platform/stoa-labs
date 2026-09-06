// Package render derives the concrete security-policy bundle an API must carry
// from its data-integrity classification AND its network exposure — the Phase-3
// engine of ADR-076 that turns "security = f(integrity)" from a declaration
// into a machine-derived, fail-closed fact. The project repo declares a
// classification + exposure (+ tags); it NEVER picks its own policies. An
// unknown classification, an unknown exposure, an ungoverned (classification,
// exposure) cell, or an inconsistent auth-exception is REJECTED (fail-closed) —
// a project cannot ship a posture weaker than its integrity level.
//
// # The two axes are ORTHOGONAL, and this package is their SINGLE authority
//
// Classification (VH/H/M) answers "how much does corrupting this data cost?".
// Exposure (internal/external/internet) answers "who can reach it?" — the
// OWASP API9:2023 inventory axis (internal / partners / public), transposed to
// the client's vocabulary. Neither is a rescaling of the other: a Medium API on
// the public internet and a Very-High API inside the SI carry DIFFERENT
// bundles, and neither dominates the other (ADR-091, GOAL posture-par-exposition
// jalon P1).
//
// Every other site that needs the vocabulary — governance.ValidateUAC, the
// central classification registry (govsource), the UAC JSON schema — derives it
// from HERE (the schema by a pinned drift test, since JSON cannot import Go).
// Before P1 the enum was hand-copied at four sites; a value added at one and
// forgotten at another is exactly the silent divergence this package now makes
// impossible.
package render

import (
	"fmt"
	"sort"
	"strings"
)

// The governed exposure vocabulary (ADR-091). Inbound, all three: the value
// names WHO may call the API, never what the API calls out to.
//
//	ExposureInternal — caller inside the SI; internal IdP (wM LOCAL / internal realm).
//	ExposureExternal — caller is an identified PARTNER; partner IdP + the partner's
//	                   source IPs are enumerable, so an ip-allowlist is mandatory.
//	ExposureInternet — caller is the PUBLIC; NOT enumerable, so an ip-allowlist is
//	                   forbidden (a public allowlist is either impossible or a
//	                   0.0.0.0/0 fiction that satisfies the gate while protecting
//	                   nothing) and is REPLACED by anti-abuse threat protection.
const (
	ExposureInternal = "internal"
	ExposureExternal = "external"
	ExposureInternet = "internet"
)

// The governed integrity vocabulary (client literal scale, ADR-076).
const (
	ClassificationVH = "VH"
	ClassificationH  = "H"
	ClassificationM  = "M"
)

// Policy identifiers produced by this engine. Named because they cross package
// boundaries: the apply-side pre-check (internal/enforce) and every adapter's
// read-back verifier switch on these exact strings.
const (
	PolicyOAuth2           = "oauth2"
	PolicyMTLS             = "mtls"
	PolicyAPIKey           = "apikey"
	PolicyRateLimit        = "rate-limit"
	PolicyAuditLog         = "audit-log"
	PolicyIPAllowlist      = "ip-allowlist"
	PolicyHTTPSOnly        = "https-only"
	PolicyThreatProtection = "threat-protection"
)

// Input is the security-relevant subset of a UAC contract.
type Input struct {
	Classification string   // VH | H | M
	Exposure       string   // internal | external | internet | "" (defaults internal)
	Tags           []string // orthogonal key:value tags (e.g. auth-exception:apikey)
}

// Result is the derived authn method, the named bouquet of the truth-table cell
// that produced it, the ordered deduped policy bundle, and — since P4 — the
// SPLIT of that bundle into what one shared object can carry for the whole cell
// and what stays attached to the individual API.
type Result struct {
	Authn            string   // oauth2+mtls | oauth2 | apikey
	Bundle           string   // named cell of the truth table, e.g. "vh-internet"
	RequiredPolicies []string // stable, sorted policy identifiers
	CommonPolicies   []string // subset carried by the cell's global policy (P4)
	PerAPIPolicies   []string // the remainder — attached to the API itself
	Quota            Quota    // the cell's governed rate-limit quota (P4)
	EntryProtocol    string   // the transport-stage entry protocol to pin (P5), "" when none
	CallerIdentity   []string // IAM identification dimensions to require (P6), nil when none
}

// Quota is the governed rate limit of a truth-table cell: the ONLY parameter on
// which two cells' COMMON bundles differ, and therefore the thing that makes
// "rate-limit" a control rather than a word.
//
// A cell that names `rate-limit` without saying how much would leave the number
// to whoever writes the gateway object — that is, to the requester, which is
// precisely what this GOAL forbids. So the number lives HERE, per named cell,
// exactly like the bouquet name itself (ADR-091 discipline: a cell without a
// name is a refusal; since P4, a cell without a quota is one too).
type Quota struct {
	Requests int    // maximum invocations per interval, all consumers together
	Interval int    // length of the window
	Unit     string // window unit, in the product's vocabulary (minutes|hours|days|weeks)
}

// AuthExceptionApiKey is the tag that (only for M + internal) swaps OAuth2 for
// an ApiKey-only posture — the single governed downgrade the client scale allows.
const AuthExceptionApiKey = "auth-exception:apikey"

// CodeIntegrityInconsistent is the machine code for "this contract's integrity
// level yields no valid bundle" — SHARED by the validate-side gate
// (governance.ValidateUAC) and the apply-side gate (cmd/labctl), so the code
// announced stable to CI consumers cannot drift between the two sites.
const CodeIntegrityInconsistent = "INTEGRITY_INCONSISTENT"

// bundleNames IS the truth table: exactly one NAMED bouquet per governed
// (classification, exposure) cell, and nothing outside it. A pair absent from
// this map is REFUSED — so extending either vocabulary is a per-cell decision
// taken here, never an implicit generalisation that silently invents a posture
// for a combination nobody arbitrated.
//
// The named cells (P1 porte, GOAL posture-par-exposition):
//
//	          internal        external          internet
//	VH     vh-internal      vh-external      vh-internet
//	 H      h-internal       h-external       h-internet
//	 M      m-internal       m-external       m-internet
//
// Plus the one governed exception cell, m-internal-apikey (see Derive).
var bundleNames = map[string]map[string]string{
	ClassificationVH: {
		ExposureInternal: "vh-internal",
		ExposureExternal: "vh-external",
		ExposureInternet: "vh-internet",
	},
	ClassificationH: {
		ExposureInternal: "h-internal",
		ExposureExternal: "h-external",
		ExposureInternet: "h-internet",
	},
	ClassificationM: {
		ExposureInternal: "m-internal",
		ExposureExternal: "m-external",
		ExposureInternet: "m-internet",
	},
}

// floorPolicies apply to EVERY cell, at every level and every exposure.
//
// https-only is a floor since P1 (client decision, 2026-09-04): the accepted
// entry protocol is pinned per API on the transport stage (entryProtocolPolicy,
// measured live at GOAL spike C) — a per-API lever that costs no restart and so
// never crosses the zero-downtime constraint of ADR-079. Adding an HTTPS
// LISTENER is a different, environment-scoped gesture that decides nothing for
// the API; spike C measured exactly that (an API served on a fresh HTTPS
// listener is still refused by its own entryProtocolPolicy=http).
var floorPolicies = []string{PolicyRateLimit, PolicyAuditLog, PolicyHTTPSOnly}

// exposurePolicies is the exposure axis' own contribution — the "règle propre"
// of each value. internal adds nothing; the two outward values add opposite
// controls, which is precisely why exposure is NOT a ladder (see Weaker).
var exposurePolicies = map[string][]string{
	ExposureInternal: nil,
	ExposureExternal: {PolicyIPAllowlist},
	ExposureInternet: {PolicyThreatProtection},
}

// commonCarriable is the set of bundle policies that ONE shared object carries
// for every API of a cell — those whose enforcement takes no per-API parameter,
// whose gateway surface was MEASURED to work inside a global policy, AND which
// no other jalon already owns end to end (GOAL jalon P4 spike, 2026-09-05,
// webMethods 10.15 réelle):
//
//	audit-log   -> stage `LMT`, action logInvocation (spike S1).
//	rate-limit  -> stage `LMT`, action throttle, carrying the cell's governed
//	               quota — measured biting the data plane with a 429 past the
//	               limit, and not biting an API outside the scope (spike S3).
//
// Deliberately NOT here, each for a stated reason — this list is a record of
// what was measured and arbitrated, not a preference:
//
//	https-only        : MEASURED portable (spike S5: a global policy at stage
//	                    `transport` with entryProtocolPolicy=https makes the
//	                    targeted API refuse the clear-text call while an API
//	                    outside the scope still answers). It stays PER-API all
//	                    the same, and the GOAL's open arbitration between P4 and
//	                    P5 is settled that way ON PURPOSE: P1 already verifies
//	                    it at read-back on the API's OWN transportProtocol
//	                    (verifyHTTPSOnly). Moving the ENFORCEMENT to a shared
//	                    object while the VERIFICATION keeps reading the API is
//	                    how a control quietly stops being verified — and P5 owns
//	                    the whole HTTPS axis, listener included. One axis, one
//	                    owner; P5 may still consolidate both halves later, and
//	                    the measurement is on file for the day it does.
//	threat-protection : the `threatProtection` stage EXISTS in the product's
//	                    stages.json, but /policies REFUSES it (HTTP 400,
//	                    NullPointerException) for two different filters and for
//	                    both scoped and unscoped policies. Its only surface is
//	                    /administration/threatprotection, which is gateway-wide
//	                    and therefore cannot differ per cell (spike S4). This
//	                    REFINES écart #1 of ADR-091 instead of closing it.
//	ip-allowlist      : no policy surface at all, and the application-identifier
//	                    form is measured fail-open (ADR-078).
//	oauth2/mtls/apikey: the IAM stage needs the API's OWN issuer, audience and
//	                    alias — nothing about it is common to a cell.
var commonCarriable = map[string]bool{
	PolicyAuditLog:  true,
	PolicyRateLimit: true,
}

// bundleQuotas gives EVERY named cell its governed quota. Same discipline as
// bundleNames: a cell absent from this map derives nothing, so extending the
// truth table forces the quota decision instead of silently inheriting one.
//
// The numbers are DEFAULTS with a stated rationale, and they are a client
// decision (ADR-094): the quota falls as the caller population widens (an
// internal caller set is bounded and identified, the public one is not) and, at
// equal exposure, as the integrity stake rises (the more a corruption costs, the
// less room an abusive burst deserves). What P4 delivers is the mechanism that
// makes the number governed and machine-applied; the values themselves are the
// client's to set.
var bundleQuotas = map[string]Quota{
	"vh-internal":       {Requests: 120, Interval: 1, Unit: QuotaUnitMinutes},
	"vh-external":       {Requests: 60, Interval: 1, Unit: QuotaUnitMinutes},
	"vh-internet":       {Requests: 30, Interval: 1, Unit: QuotaUnitMinutes},
	"h-internal":        {Requests: 300, Interval: 1, Unit: QuotaUnitMinutes},
	"h-external":        {Requests: 150, Interval: 1, Unit: QuotaUnitMinutes},
	"h-internet":        {Requests: 60, Interval: 1, Unit: QuotaUnitMinutes},
	"m-internal":        {Requests: 600, Interval: 1, Unit: QuotaUnitMinutes},
	"m-external":        {Requests: 300, Interval: 1, Unit: QuotaUnitMinutes},
	"m-internet":        {Requests: 120, Interval: 1, Unit: QuotaUnitMinutes},
	"m-internal-apikey": {Requests: 600, Interval: 1, Unit: QuotaUnitMinutes},
}

// QuotaUnitMinutes is the product's smallest window unit (measured: the throttle
// action accepts minutes|hours|days|weeks|calendar_week|calendar_month).
const QuotaUnitMinutes = "minutes"

// PosturePolicyPrefix is the NAME namespace the platform reserves for the one
// global policy per truth-table cell. Composed here for the same reason
// PostureTag is: the Ansible role and the bootstrap play receive a FINISHED
// string from `labctl posture` and never concatenate a prefix of their own.
const PosturePolicyPrefix = "posture-"

// PosturePolicyName is the name of the cell's global policy — the single object
// that carries the cell's common bundle for every API in it.
func PosturePolicyName(bundle string) string {
	return PosturePolicyPrefix + bundle
}

// PostureMemberSentinel is the member name a cell's global policy carries when
// it has no real member.
//
// It is not decoration. MEASURED on the real 10.15 (spike S7): a scope condition
// of filterType API with ZERO attributes does not select nothing — it selects
// EVERY API on the gateway. A cell policy created empty at day 0, or emptied by
// removing its last member, would therefore apply that cell's quota and protocol
// restriction to the whole gateway. The sentinel is a name no API bears, and it
// was measured to select nothing.
const PostureMemberSentinel = "__posture_aucune_api__"

// Cells returns every named cell of the truth table, in a stable order. The
// bootstrap play iterates over THIS rather than over a list of its own.
func Cells() []string {
	out := make([]string, 0, len(bundleQuotas))
	for c := range bundleQuotas {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// QuotaFor returns the governed quota of a named cell, and whether the cell is
// governed at all. Fail-closed by construction: an unknown cell has no quota.
func QuotaFor(bundle string) (Quota, bool) {
	q, ok := bundleQuotas[bundle]
	return q, ok
}

// EntryProtocolHTTPS is the value the transport stage's `entryProtocolPolicy`
// action must carry for an API that refuses the clear-text call, in the
// PRODUCT's own vocabulary (jalon P5, ADR-095).
//
// MEASURED on the real 10.15, not read from a contract (spike P5):
//   - a freshly imported API already carries a `transport` stage with an
//     `entryProtocolPolicy` action, whose value is ["http"] — so the platform
//     EDITS an existing object rather than creating one (S1);
//   - the action is PROPER to each API — unlike the LMT throttle action, which
//     P4 measured to be shared — so pinning one API's protocol has no side
//     effect on any other (S2);
//   - the parameter is EXCLUSIVE, not additive: ["https"] refuses the clear
//     call with HTTP 500 « Transport protocol not supported », and putting
//     ["http"] back makes it pass again — the same lever both ways (S4/S5).
const EntryProtocolHTTPS = "https"

// EntryProtocolFor returns the entry protocol the platform must pin on the
// API's OWN transport stage, and "" when nothing is to be pinned there.
//
// IT READS THE PER-API HALF ON PURPOSE, and that is the whole point of this
// function existing rather than a constant. P4 measured that `https-only` is
// portable by a cell's global policy and deliberately left it per-API, because
// P1 verifies it at read-back on the API's own transportProtocol
// (verifyHTTPSOnly): moving the ENFORCEMENT to a shared object while the
// VERIFICATION keeps reading the API is how a control quietly stops being
// verified. Deriving the protocol from PerAPIPolicies makes that coupling
// MECHANICAL — the day someone moves `https-only` into commonCarriable, this
// returns "" and the publish role stops posing it, instead of two halves of one
// control drifting apart in silence. TestEntryProtocolFollowsTheHalfThatOwnsIt
// pins the equivalence.
func EntryProtocolFor(perAPI []string) string {
	for _, p := range perAPI {
		if p == PolicyHTTPSOnly {
			return EntryProtocolHTTPS
		}
	}
	return ""
}

// IdentificationIPRange is the webMethods identification type that resolves a
// caller by the SOURCE IP of its request, matched against the `ipAddressRange`
// identifier of a consumer application subscribed to the API.
//
// MEASURED on the real 10.15 (spike P6, 2026-09-06), and the measurement is the
// whole reason this exists:
//   - a published API with an EMPTY IAM stage serves ANY caller, anonymously
//     (S1) — there is no deny-by-default to "wake up", there is one to POSE;
//   - an application carrying an ipAddressRange identifier opposes NOTHING as
//     long as no IAM rule requires that dimension: the out-of-range caller is
//     served 200 (S2). That is the fail-open ADR-078 named and left open, and
//     it is the state of every `external` cell the chain has published so far;
//   - with the rule posed, the SAME caller on the SAME API gets 403 when the
//     range excludes it and 200 when it includes it, while a call from another
//     origin stays refused (S3) — and removing the rule makes it pass again at
//     unchanged range (S4);
//   - a range of 0.0.0.0-255.255.255.255 does NOT identify anybody (S3): a
//     "wildcard allow-list" is refused like an absent one, so the dimension can
//     never be satisfied by widening it to everything.
const IdentificationIPRange = "ipAddressRange"

// CallerIdentityFor returns the identification dimensions the platform must
// require on the API's OWN IAM stage, and nil when the cell requires none.
//
// IT READS THE PER-API HALF, for the same mechanical reason as EntryProtocolFor:
// `ip-allowlist` has no shared-object surface at all (P4 measured that, and
// commonCarriable records it), so the day someone moves it to the common half
// this returns nil and the publish role stops posing — instead of a control
// whose ENFORCEMENT drifts to one object while its VERIFICATION keeps reading
// another. TestCallerIdentityFollowsTheHalfThatOwnsIt pins the equivalence.
//
// It deliberately does NOT derive the oauth2/mtls dimensions, which the
// inbound-auth leg owns end to end (ADR-075/078) with the API's own issuer,
// audience and alias. P6 owns ONE axis: the network restriction. The role
// UNIONS the two sets into a single action, because the gateway accepts exactly
// one action on the IAM stage (409 on a second — spike P6 S7).
func CallerIdentityFor(perAPI []string) []string {
	var out []string
	for _, p := range perAPI {
		if p == PolicyIPAllowlist {
			out = append(out, IdentificationIPRange)
		}
	}
	return out
}

// PostureTagPrefix is the tag NAMESPACE the platform RESERVES inside an API's
// OpenAPI tags (`apiDefinition.tags` on webMethods 10.15 — the only writable
// tag carrier, `apiTags` being a dead field; measured at GOAL spike A/D).
//
// It exists because that field is SHARED with the producer: the tags of the
// OpenAPI contract land there, and the platform writes its own posture tag in
// the same list. Ownership therefore cannot be expressed by "who wrote last" —
// it is expressed by this namespace. Every tag carrying this prefix belongs to
// the platform; the role strips ALL of them before posing exactly the one it
// derived, so a contract that ships `posture:m-internal` to look tamer than it
// is loses that tag rather than gaining a lie (jalon P3).
//
// Tags OUTSIDE the namespace are the producer's and are preserved untouched:
// OpenAPI operations REFERENCE their tags by name (`operation.tags`), so wiping
// the list wholesale would dangle those references and break the grouping the
// producer documents with — a functional regression with no security dividend.
const PostureTagPrefix = "posture:"

// PostureTag is the single tag the platform poses on an API for a derived
// bundle: the NAMED cell of the truth table, inside the reserved namespace.
//
// Composed HERE and nowhere else. The chain that actually writes it is Ansible
// (roles/apim_publish_api/tasks/tag.yml), which cannot import Go; it receives
// the finished string from `labctl posture` rather than concatenating a prefix
// of its own — the same reason P2 gave the chain a command instead of a Jinja
// re-implementation of the truth table (ADR-091/ADR-092).
func PostureTag(bundle string) string {
	return PostureTagPrefix + bundle
}

// Exposures returns the governed exposure vocabulary, ordered from the least to
// the most widely reachable. The order is presentational (messages, schema
// drift test); it carries NO security ordering — see Weaker.
func Exposures() []string {
	return []string{ExposureInternal, ExposureExternal, ExposureInternet}
}

// Classifications returns the governed integrity vocabulary, strongest first.
func Classifications() []string {
	return []string{ClassificationVH, ClassificationH, ClassificationM}
}

// ValidExposure reports whether e is a governed exposure. The empty string is
// NOT valid here: defaulting is EffectiveExposure's job, and a caller that
// wants "absent means internal" must say so by calling it.
func ValidExposure(e string) bool {
	_, ok := exposurePolicies[e]
	return ok
}

// ValidClassification reports whether c is a governed integrity level.
func ValidClassification(c string) bool {
	_, ok := bundleNames[c]
	return ok
}

// EffectiveExposure is the single place the empty-exposure default lives:
// Derive, the enforcement requirement and the render command all report the
// SAME effective value.
func EffectiveExposure(exposure string) string {
	if exposure == "" {
		return ExposureInternal
	}
	return exposure
}

// classificationRank orders the integrity levels (VH strongest). 0 = unknown.
// Used by the central-registry gate (goal A5) to tell a DOWNGRADE (project
// weaker than the governed level = spoof) from over-declaration (project
// stronger = harmless over-provisioning).
func classificationRank(c string) int {
	switch c {
	case ClassificationVH:
		return 3
	case ClassificationH:
		return 2
	case ClassificationM:
		return 1
	}
	return 0
}

// Weaker reports whether posture (class, exposure) is WEAKER than the governed
// (wantClass, wantExposure) — the anti-spoof comparison of the central registry
// gate (goal A5).
//
// Two guards, because the two axes are not the same kind of thing:
//
//  1. INTEGRITY is a ladder: a lower classification rank is a downgrade, even
//     when the two levels happen to derive the same bundle today (M and H both
//     yield oauth2 — declaring M when the registry says H is still an attempt).
//
//  2. EXPOSURE is NOT a ladder, and P1 is where that stops being a footnote.
//     Since internet REPLACES ip-allowlist with threat-protection instead of
//     adding to it, BOTH directions lose a mandatory control: declaring
//     internal when the registry says internet drops threat-protection, and
//     declaring internet when it says external drops the ip-allowlist. No rank
//     can express that. So the exposure guard is BUNDLE CONTAINMENT, derived
//     mechanically: the declared posture is weaker as soon as its bundle fails
//     to contain every policy of the governed one.
//
// Containment is computed WITHOUT tags on both sides — the central registry
// carries (classification, exposure) only, so the apikey exception stays out of
// this comparison exactly as it was before P1. Fail-closed: if either side does
// not derive, the answer is "weaker".
func Weaker(class, exposure, wantClass, wantExposure string) bool {
	if classificationRank(class) < classificationRank(wantClass) {
		return true
	}
	got, gerr := Derive(Input{Classification: class, Exposure: exposure})
	want, werr := Derive(Input{Classification: wantClass, Exposure: wantExposure})
	if gerr != nil || werr != nil {
		return true
	}
	have := make(map[string]bool, len(got.RequiredPolicies))
	for _, p := range got.RequiredPolicies {
		have[p] = true
	}
	for _, p := range want.RequiredPolicies {
		if !have[p] {
			return true
		}
	}
	return false
}

// Derive computes the required policy bundle, fail-closed (ADR-076/ADR-091).
//
// Integrity axis:
//
//	VH -> oauth2 + mtls ; H -> oauth2 ; M -> oauth2 (default)
//	M + tag auth-exception:apikey + exposure internal -> apikey (governed exception)
//
// Exposure axis:
//
//	internal -> nothing more
//	external -> + ip-allowlist   (the partner's source IPs ARE enumerable)
//	internet -> + threat-protection, and NO ip-allowlist (the public's are not)
//
// Floor, every cell: rate-limit + audit-log + https-only.
//
// VH x internet is GOVERNED, not forbidden: a client certificate is
// distributable to a public caller even though its IP is not — that is the
// eIDAS/QWAC model (client decision, 2026-09-04). Only the ip-allowlist becomes
// untenable at that exposure, never the certificate.
//
// Rejected: unknown classification; unknown exposure; a (classification,
// exposure) cell absent from the truth table; an apikey exception on a
// non-M level or a non-internal exposure.
func Derive(in Input) (Result, error) {
	if !ValidClassification(in.Classification) {
		return Result{}, fmt.Errorf("classification %q inconnue (attendu %s)",
			in.Classification, strings.Join(Classifications(), ", "))
	}

	exposure := EffectiveExposure(in.Exposure)
	if !ValidExposure(exposure) {
		return Result{}, fmt.Errorf("exposure %q invalide (attendu %s)",
			in.Exposure, strings.Join(Exposures(), ", "))
	}

	// The cell must be NAMED to exist. Both vocabularies are valid above, so
	// this only fires when the truth table is extended on one axis and not
	// arbitrated on the other — fail-closed by construction, never a default.
	bundle := bundleNames[in.Classification][exposure]
	if bundle == "" {
		return Result{}, fmt.Errorf("combinaison classification=%s exposure=%s non gouvernée (aucun bouquet nommé dans la table de vérité)",
			in.Classification, exposure)
	}

	apikeyException := false
	for _, t := range in.Tags {
		if t == AuthExceptionApiKey {
			apikeyException = true
		}
	}

	policies := map[string]bool{}
	for _, p := range floorPolicies {
		policies[p] = true
	}
	for _, p := range exposurePolicies[exposure] {
		policies[p] = true
	}

	var authn string
	switch {
	case apikeyException:
		if in.Classification != ClassificationM {
			return Result{}, fmt.Errorf("%s interdite pour la classification %s (uniquement M)", AuthExceptionApiKey, in.Classification)
		}
		if exposure != ExposureInternal {
			return Result{}, fmt.Errorf("%s interdite en exposure %s (uniquement internal)", AuthExceptionApiKey, exposure)
		}
		authn = PolicyAPIKey
		policies[PolicyAPIKey] = true
		bundle += "-apikey"
	case in.Classification == ClassificationVH:
		authn = "oauth2+mtls"
		policies[PolicyOAuth2] = true
		policies[PolicyMTLS] = true
	default: // H, M
		authn = PolicyOAuth2
		policies[PolicyOAuth2] = true
	}

	out := make([]string, 0, len(policies))
	for p := range policies {
		out = append(out, p)
	}
	sort.Strings(out)

	// P4: the bundle SPLITS mechanically. Nothing here decides which side a
	// policy falls on — commonCarriable does, from what the gateway was
	// measured to accept in a shared object. Adding a policy to the truth table
	// without deciding its side therefore leaves it per-API, which is the
	// conservative half.
	common := make([]string, 0, len(out))
	perAPI := make([]string, 0, len(out))
	for _, p := range out {
		if commonCarriable[p] {
			common = append(common, p)
		} else {
			perAPI = append(perAPI, p)
		}
	}

	// A named cell WITHOUT a governed quota is a refusal, not a cell with no
	// rate limit: `rate-limit` is in every cell'"'"'s floor, and shipping it with no
	// number would leave the number to whoever writes the gateway object.
	quota, governed := QuotaFor(bundle)
	if !governed {
		return Result{}, fmt.Errorf("bouquet %s sans quota gouverné (aucune entrée dans la table des quotas) : `%s` serait un mot, pas un contrôle",
			bundle, PolicyRateLimit)
	}

	return Result{
		Authn:            authn,
		Bundle:           bundle,
		RequiredPolicies: out,
		CommonPolicies:   common,
		PerAPIPolicies:   perAPI,
		Quota:            quota,
		// P5: derived from the PER-API half, never from the bundle at large —
		// see EntryProtocolFor. Empty is a legitimate answer, and the role
		// treats it as "pose nothing", not as "pose the default".
		EntryProtocol: EntryProtocolFor(perAPI),
		// P6: same discipline, same half. Empty means the cell requires no
		// caller-identification dimension of its own, NOT that anonymous is
		// fine — the other dimensions stay owned by the inbound-auth leg.
		CallerIdentity: CallerIdentityFor(perAPI),
	}, nil
}
