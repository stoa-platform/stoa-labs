"""gateway.py — inventaire depuis l'API d'administration.

Deux parties nettement separees :
  - des fonctions PURES de normalisation, testees sur les fixtures capturees
    en T0 (voir carto/TERRAIN.md) : c'est la que vit toute la logique ;
  - une coquille HTTP mince (classe Gateway), la seule I/O du module.

Les noms de champs viennent de mesures reelles sur une gateway webMethods
10.15 (T0), pas de suppositions : un shape suppose est un bug silencieux.
Deux pieges mesures a retenir :
  - `GET /apis` renvoie une liste imbriquee sous la cle racine `apiResponse`,
    ou chaque element est une enveloppe {"api": {...}, "teams": [...], ...} :
    l'objet API utile est imbrique sous `api`, et son proprietaire n'est pas
    sur cet objet mais dans `teams`, frere de `api` dans l'enveloppe.
  - `GET /applications` renvoie une liste plate sous `applications`, ou
    `consumingAPIs` est une liste d'identifiants d'API en chaines brutes
    (pas d'objets) : c'est le lien declare Application -> APIs autorisees.

LECTURE SEULE : ce module n'emet que des GET.
"""
import base64
import json
import re
import urllib.parse
import urllib.request
import urllib.error

# --- constantes mesurees en T0 (carto/TERRAIN.md) -------------------------
# Mettre None quand le champ n'existe pas cote Gateway.

# GET /apis -> {"apiResponse": [{"api": {...}, "teams": [...], ...}, ...]}
API_ROOT_KEY = "apiResponse"
# Chemin, dans chaque element de la liste racine, vers l'objet API imbrique.
API_ENVELOPE_KEY = "api"
# Chemin, dans chaque element de la liste racine (frere de l'objet api), vers
# la liste des equipes {"id", "name", "source"} — sert a deriver "owner".
API_TEAMS_KEY = "teams"
API_FIELDS = {
    "id": "id",
    "name": "apiName",
    "version": "apiVersion",
    "active": "isActive",
    # absent de la liste /apis (mesure en T0) : jamais devine, reste a None.
    "createdAt": None,
}

# GET /applications -> {"applications": [{...}, ...]} (structure plate)
APP_ROOT_KEY = "applications"
APP_FIELDS = {
    "id": "id",
    "name": "name",
    "owner": "owner",
    "contact": "contactEmails",
    "createdAt": "created",
}

# Chemin, dans un objet Application, vers la liste des identifiants d'APIs
# autorisees. Mesure en T0 : liste de chaines brutes (UUID), pas d'objets.
DECLARED_PATH = ("consumingAPIs",)

# Format mesure en T0 pour APP_FIELDS["createdAt"] : "2026-07-29 15:51:37 GMT"
_CREATED_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$"
)
# --------------------------------------------------------------------------


def _pick(obj, field):
    return obj.get(field) if field and isinstance(obj, dict) else None


def _rows(raw, root_key):
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        return raw.get(root_key) or []
    return []


def _first(value):
    """Un contact peut arriver en liste (contactEmails) ou en scalaire."""
    if isinstance(value, list):
        return value[0] if value else None
    return value


def _to_iso8601_utc(value):
    """Normalise "AAAA-MM-JJ HH:MM:SS GMT" en ISO 8601 UTC ("...Z").

    Retourne None si la valeur est absente ou d'un format inattendu : on ne
    devine jamais un format de date, on refuse plutot de produire une valeur
    erronee.
    """
    if not isinstance(value, str):
        return None
    m = _CREATED_RE.match(value.strip())
    if not m:
        return None
    y, mo, d, h, mi, s = m.groups()
    return f"{y}-{mo}-{d}T{h}:{mi}:{s}Z"


def _api_owner(envelope):
    """Proprietaire d'une API : nom de la premiere equipe non-SYSTEM dans
    `teams` (frere de `api` dans l'enveloppe). None si aucune equipe metier
    n'est declaree (les equipes SYSTEM comme Administrators sont du bruit
    d'administration, pas un proprietaire)."""
    teams = envelope.get(API_TEAMS_KEY) if isinstance(envelope, dict) else None
    for team in teams or []:
        if isinstance(team, dict) and team.get("source") != "SYSTEM":
            return team.get("name")
    return None


def normalize_apis(raw):
    """Deballe l'enveloppe apiResponse[] et normalise chaque API."""
    out = []
    for envelope in _rows(raw, API_ROOT_KEY):
        a = envelope.get(API_ENVELOPE_KEY, {}) if isinstance(envelope, dict) else {}
        out.append({
            "id": _pick(a, API_FIELDS["id"]),
            "name": _pick(a, API_FIELDS["name"]),
            "version": _pick(a, API_FIELDS["version"]),
            "owner": _api_owner(envelope),
            "active": bool(_pick(a, API_FIELDS["active"])),
            "createdAt": _pick(a, API_FIELDS["createdAt"]),
        })
    return out


def normalize_consumers(raw):
    out = []
    for c in _rows(raw, APP_ROOT_KEY):
        out.append({
            "id": _pick(c, APP_FIELDS["id"]),
            "name": _pick(c, APP_FIELDS["name"]),
            "owner": _pick(c, APP_FIELDS["owner"]),
            "contact": _first(_pick(c, APP_FIELDS["contact"])),
            "createdAt": _to_iso8601_utc(_pick(c, APP_FIELDS["createdAt"])),
        })
    return out


def declared_edges(raw_apps):
    """Couples (apiId, consumerId) autorises par configuration.

    consumingAPIs est une liste d'identifiants d'API en chaines brutes
    (mesure en T0) : pas d'objets a deballer, une chaine vide ou une liste
    vide ne produit simplement aucune arete pour cette application.
    """
    edges = set()
    for c in _rows(raw_apps, APP_ROOT_KEY):
        con_id = _pick(c, APP_FIELDS["id"])
        node = c
        for key in DECLARED_PATH:
            node = (node or {}).get(key) if isinstance(node, dict) else None
        for item in node or []:
            api_id = item.get("apiId") or item.get("id") if isinstance(item, dict) else item
            if api_id and con_id:
                edges.add((api_id, con_id))
    return edges


class Gateway:
    """Coquille HTTP en lecture seule sur l'API d'administration."""

    def __init__(self, base_url, user, password, timeout=30):
        self.base = base_url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.timeout = timeout

    def get(self, path, params=None):
        """GET sur l'API d'administration. `params` est encode en query string.

        C'est aussi la fonction injectee dans `analytics.collect` : tout le
        trafic de la carto passe donc par ce seul point d'I/O, avec les memes
        identifiants et la meme absence d'ecriture. Les valeurs sont encodees
        par `urlencode` — les filtres de la gateway sont des expressions
        regulieres, donc porteurs de caracteres qu'une concatenation naive
        casserait.
        """
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, method="GET")
        req.add_header("Accept", "application/json")
        req.add_header("Authorization", self.auth)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as err:
            # La gateway explique ses refus dans le CORPS de la reponse
            # (`{"errorDetails": " Insufficient parameters. ..."}`), avec un
            # code 400. Sans cette relecture, l'exploitant ne lit que
            # « HTTP Error 400: Bad Request » et n'a aucun geste a poser.
            detail = ""
            try:
                detail = json.loads(err.read().decode()).get("errorDetails", "")
            except Exception:
                pass
            raise urllib.error.HTTPError(
                err.url, err.code, f"{err.reason} —{detail or ' (aucun detail)'} "
                f"[{path}]", err.headers, None) from None

    def apis(self):
        return self.get("/apis")

    def applications(self):
        return self.get("/applications")
