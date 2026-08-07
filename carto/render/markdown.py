"""markdown.py — la carto en pages Markdown, pour un depot git dedie.

Fonction PURE : `carto.json` + `history.json` -> un dictionnaire
{nom de page: texte}. Aucune I/O, aucun appel a git, aucune horloge. C'est ce
qui rend le determinisme testable octet pour octet.

─────────────────────────────────────────────────────────────────────────────
LA CONTRAINTE QUI GOUVERNE TOUT CE FICHIER : UN DIFF QUI EST DU BRUIT DETRUIT
LA DEMARCHE
─────────────────────────────────────────────────────────────────────────────
Ces pages existent pour une raison precise : chez le client il n'y a pas de
serveur web, il y a git. La forge rend le Markdown, et surtout le `git diff`
d'un jour a l'autre repond a « qu'est-ce qui a bouge cette semaine ? » avec une
date et un auteur, sans aucune infrastructure nouvelle.

Cette promesse ne tient QUE si le diff ne montre que ce qui a bouge dans la
plateforme. Trois regles, non negociables, chacune gardee par un test :

1. **Tri stable et deterministe partout, par NOM, jamais par volume.** Les
   volumes changent tous les jours ; trier par volume ferait valser toutes les
   lignes en permanence pour aucune information. La vue HTML, elle, trie par
   volume — c'est le bon choix pour un ecran qu'on lit une fois, et le mauvais
   pour un fichier qu'on diffe tous les jours. Les deux rendus divergent ici
   volontairement.
2. **Aucune valeur qui change sans raison.** Pas d'horodatage a la seconde la
   ou la date suffit (`generatedAt` est tronque au jour), pas d'identifiant
   aleatoire, pas d'ordre de dictionnaire non trie, aucun « il y a N jours »
   calcule a l'affichage.
3. **Ordre chronologique CROISSANT dans la table d'evolution.** Une semaine de
   plus est alors une ligne ajoutee en fin de fichier, pas un decalage de
   toutes les lignes. La vue HTML affiche la plus recente en haut ; ici c'est
   le diff qui commande.

Le tri par nom est fait sur `casefold()` puis sur la chaine brute puis sur
l'identifiant : un ordre TOTAL, sans locale (`locale.strxfrm` dependrait de la
machine qui execute le job — donc du bruit de diff des qu'un agent change).

─────────────────────────────────────────────────────────────────────────────
LA FRAICHEUR EST UN PIEGE
─────────────────────────────────────────────────────────────────────────────
Une page Markdown perimee dans git a EXACTEMENT l'air d'une page fraiche : ni
bandeau orange, ni erreur de chargement, rien. La date de collecte est donc en
tete de chaque page, et le texte porte lui-meme la regle de lecture (« si cette
date n'est ni celle d'aujourd'hui ni celle d'hier, la collecte ne tourne
plus »). C'est aussi la raison pour laquelle cette date fait partie du corpus
compare avant de commiter : voir `carto/scripts/publier-markdown.sh`, qui
explique l'arbitrage complet du commit conditionnel.
"""

import datetime as dt

from ..collect.build import gating_share
from ..collect.model import SCHEMA_VERSION

# Libelle humain de chaque fenetre, pour NOMMER celle sur laquelle la part non
# identifiee a ete jugee. Sans le nom, le meme pourcentage veut dire deux
# choses tres differentes selon la fenetre — et le lecteur ne peut pas savoir
# laquelle.
_LIBELLE_FENETRE = {"d7": "7 derniers jours", "d30": "30 derniers jours",
                    "d90": "90 derniers jours"}


def _part_jugee(carto):
    """(part, libelle de la fenetre, heritage d90 a dire) — ou (None, ...).

    Meme regle que le bandeau HTML, et pour la meme raison mesuree le
    2026-08-07 : juger sur d90 seule, c'est ecrire « non fiable » trois mois
    apres que la cause a ete corrigee. Le chiffre d90 reste dit quand il
    differe : ne plus condamner n'est pas se taire.
    """
    par_fenetre = carto.get("unidentifiedCallShareByWindow")
    if not isinstance(par_fenetre, dict):
        # Repli sur le scalaire : document d'une version anterieure. Le
        # contrat le refuserait, mais ce rendu ne doit jamais se taire.
        brut = carto.get("unidentifiedCallShare")
        if isinstance(brut, (int, float)) and not isinstance(brut, bool):
            return brut, None, None
        return None, None, None

    fenetre, valeur = gating_share({"unidentifiedCallShareByWindow": par_fenetre})
    if fenetre is None:
        return None, "aucun trafic servi", None
    d90 = par_fenetre.get("d90")
    heritage = d90 if (fenetre != "d90" and isinstance(d90, (int, float))
                       and d90 != valeur) else None
    return valeur, _LIBELLE_FENETRE[fenetre], heritage

# Ordre de generation ET ordre de citation dans le README. `README.md` en tete :
# c'est l'entree de la publication.
PAGES = ("README.md", "consommateurs.md", "apis.md", "evolution.md")

# Fichiers de donnees deposes a cote des pages. Nommes ici parce que les pages
# y renvoient : un lien vers un fichier absent est une promesse non tenue.
FICHIERS_DONNEES = ("carto.json", "history.json", "index.html")

# Seuil d'alerte sur la part du trafic non rattachee a un consommateur
# identifie. MEME VALEUR que `SEUIL_NON_IDENTIFIE` dans `render/index.html`,
# que `carto_seuil_non_identifie_pct` du role Ansible et que le defaut du
# parametre `SEUIL_NON_IDENTIFIE_PCT` du Jenkinsfile : la page, le deploiement
# et le build doivent s'alarmer au MEME moment. Un test garde l'egalite avec la
# page HTML.
SEUIL_NON_IDENTIFIE = 0.5

_ESPACE = "\u00a0"          # insecable : sépare les milliers et précède « % »


class VersionNonSupportee(Exception):
    """Le document ne porte pas la version de schema que ce rendu sait lire.

    Meme refus que la page HTML, et pour la meme raison : un document d'une
    version inconnue serait lu champ par champ au hasard, et le resultat
    presente comme une mesure. Mieux vaut pas de page qu'une page qui ment —
    et, ici, une page fausse serait en plus COMMITEE, donc durable.
    """


# --- formatage ------------------------------------------------------------

def _nb(n):
    """Entier avec separateur de milliers insecable. `None` -> `0`."""
    return f"{int(n or 0):,}".replace(",", _ESPACE)


def _pct(x, decimales=1):
    """Pourcentage a la francaise : `0.9404` -> `94,0 %`."""
    return f"{x * 100:.{decimales}f}".replace(".", ",") + _ESPACE + "%"


def _jour(iso):
    """Date seule, jamais l'heure : une seconde qui bouge est du bruit de diff."""
    return iso[:10] if isinstance(iso, str) and len(iso) >= 10 else "—"


def _c(valeur):
    """Cellule de tableau : le `|` et le saut de ligne casseraient la table."""
    if valeur is None or valeur == "":
        return "—"
    return str(valeur).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def _cle_nom(objet):
    """Ordre TOTAL et sans locale : casefold, puis brut, puis identifiant.

    `casefold()` seul n'est pas un ordre total (deux noms qui ne different que
    par la casse seraient a egalite, et l'ordre retomberait sur l'ordre
    d'insertion — donc sur l'ordre de reponse de la gateway, qui n'est garanti
    par rien). L'identifiant tranche en dernier ressort.
    """
    nom = objet.get("name") or ""
    return (nom.casefold(), nom, objet.get("id") or "")


def _jours(n):
    return f"{n}\u00a0jour" + ("s" if abs(n) > 1 else "")


def _delta(courant, precedent):
    """`(+3)`, `(-1)`, `(=)`, ou chaine vide s'il n'y a rien a comparer."""
    if precedent is None:
        return ""
    d = courant - precedent
    if d == 0:
        return " (=)"
    return f" ({'+' if d > 0 else '−'}{_nb(abs(d))})"


# --- lecture du document --------------------------------------------------

def _index(carto):
    apis = {a["id"]: a for a in carto["apis"]}
    consos = {c["id"]: c for c in carto["consumers"]}
    par_api, par_conso = {}, {}
    for e in carto["edges"]:
        par_api.setdefault(e["apiId"], []).append(e)
        par_conso.setdefault(e["consumerId"], []).append(e)
    return apis, consos, par_api, par_conso


def _nom(table, ident):
    objet = table.get(ident)
    return (objet or {}).get("name") or ident


def _statut(edge):
    if not edge["declared"]:
        return "non déclaré"
    if edge["calls"]["d90"] == 0:
        return "déclaré, inactif"
    return "actif"


def _liens_tries(carto, apis, consos):
    """Les aretes, triees par NOM d'API puis NOM de consommateur.

    Jamais par volume : c'est la regle 1 de l'en-tete de ce module.
    """
    return sorted(
        carto["edges"],
        key=lambda e: (_cle_nom(apis.get(e["apiId"], {"id": e["apiId"]})),
                       _cle_nom(consos.get(e["consumerId"], {"id": e["consumerId"]}))),
    )


def _signaux(carto):
    """Les cinq signaux de la vue HTML, avec LEUR phrase d'aide.

    Les seuils et les definitions sont ceux de `render/index.html`
    (`viewSignaux`) : deux rendus du meme document ne doivent pas alerter sur
    des choses differentes. Chaque entree est deja triee.
    """
    apis, consos, par_api, _ = _index(carto)

    sans_trafic = [a for a in sorted(carto["apis"], key=_cle_nom)
                   if not any(e["calls"]["d90"] > 0 for e in par_api.get(a["id"], []))]
    liens = _liens_tries(carto, apis, consos)
    declares_inactifs = [e for e in liens if e["declared"] and e["calls"]["d90"] == 0]
    non_declares = [e for e in liens if not e["declared"] and e["calls"]["d90"] > 0]
    # Sur le champ `ghost` du contrat de donnees, jamais sur le prefixe
    # « (inconnu) » du nom : une etiquette est cosmetique, un signal ne doit
    # pas dependre d'elle.
    fantomes = sorted([o for o in carto["apis"] + carto["consumers"]
                       if o.get("ghost") is True], key=_cle_nom)
    erreurs = [e for e in liens if e["calls"]["d90"] >= 100 and e["errorRate"] > 0.05]

    lien = lambda e: (f"**{_c(_nom(consos, e['consumerId']))}** → "
                      f"**{_c(_nom(apis, e['apiId']))}**")

    return [
        ("APIs sans aucun appel",
         "Candidates à la décommission — vérifier d'abord qu'aucun consommateur "
         "déclaré n'attend d'y passer.",
         [f"**{_c(a['name'])}**" for a in sans_trafic]),
        ("Consommateurs déclarés inactifs",
         "Autorisés mais jamais vus sur la fenêtre : à relancer, pas à supprimer. "
         "Ils doivent être prévenus des changements.",
         [lien(e) for e in declares_inactifs]),
        ("Trafic sans autorisation déclarée",
         "Écart de gouvernance : du trafic observé sans lien déclaré correspondant. "
         "À investiguer.",
         [f"{lien(e)} — {_nb(e['calls']['d90'])} appels" for e in non_declares]),
        ("Objets disparus encore appelés",
         "Le trafic référence un identifiant absent de l'inventaire : objet "
         "supprimé, ou appelant non identifié.",
         [f"`{_c(o['name'])}`" for o in fantomes]),
        ("Taux d'erreur anormal",
         "Plus de 5 % d'erreurs sur au moins 100 appels.",
         [f"{lien(e)} — {_pct(e['errorRate'])}" for e in erreurs]),
    ]


def compteurs(carto):
    """Les compteurs affiches en tete du README, et resumes dans le commit.

    Meme definition que `carto/collect/history.py` (`counters`) : les noeuds
    `ghost` ne sont pas des objets enregistres. On la recalcule ici plutot que
    de la lire dans `history.json` pour que les pages restent rendues meme si
    le journal est vide au tout premier passage.
    """
    apis = [a for a in carto["apis"] if not a.get("ghost")]
    consos = [c for c in carto["consumers"] if not c.get("ghost")]
    enregistres = {c["id"] for c in consos}
    actifs = {e["consumerId"] for e in carto["edges"]
              if e["calls"]["d90"] > 0 and e["consumerId"] in enregistres}
    return {
        "date": carto["generatedAt"][:10],
        "apis": len(apis),
        "consumersRegistered": len(consos),
        "consumersActive": len(actifs),
        "calls": sum(e["calls"]["d90"] for e in carto["edges"]),
        "edges": len(carto["edges"]),
        "ghosts": len([o for o in carto["apis"] + carto["consumers"] if o.get("ghost")]),
    }


# --- semaines -------------------------------------------------------------

def _semaine(date_iso):
    """Cle de semaine ISO, `2026-S31`. Meme regle que la vue HTML (jeudi ISO)."""
    y, w, _ = dt.date.fromisoformat(date_iso).isocalendar()
    return f"{y}-S{w:02d}"


def _hebdo(history):
    """Une ligne par semaine, la DERNIERE mesure de la semaine l'emporte.

    Toutes les grandeurs du journal sont des STOCKS mesures a une date (y
    compris `calls`, total sur la fenetre glissante) : une semaine se resume
    par sa derniere valeur, JAMAIS par une somme (`carto/collect/history.py`).
    """
    par_semaine = {}
    for r in sorted(history, key=lambda r: r["date"]):
        par_semaine[_semaine(r["date"])] = r
    return [dict(r, week=s) for s, r in sorted(par_semaine.items())]


def _retro(carto):
    """Serie RETRO-CALCULEE des consommateurs enregistres, par semaine.

    Courbe de SURVIVANTS : elle ne connait que les consommateurs existant
    AUJOURD'HUI, donc elle sous-estime le passe et ne montre aucune
    disparition. Aucune serie retro pour les APIs : la gateway ne les date pas
    (`createdAt` toujours nul dans la reponse de liste — terrain V1). Ne pas
    fabriquer de date de substitution.
    """
    dates = sorted(c["createdAt"][:10] for c in carto["consumers"]
                   if c.get("createdAt"))
    cumul, out = 0, {}
    for d in dates:
        cumul += 1
        out[_semaine(d)] = cumul
    return sorted(out.items())


# --- pages ----------------------------------------------------------------

def _entete_fraicheur(carto, page_courante):
    """Bloc de tete commun a toutes les pages : date, fenetre, part non identifiee.

    Il est en TETE et en EVIDENCE parce qu'une page Markdown perimee dans git a
    exactement l'air d'une page fraiche.
    """
    c = compteurs(carto)
    w = carto.get("window") or {}
    couverte, demandee = w.get("coveredDays"), w.get("requestedDays")
    part, libelle, heritage = _part_jugee(carto)

    lignes = [f"> ### Données collectées le **{c['date']}**", ">"]

    if isinstance(couverte, int):
        txt = f"> - **Fenêtre réellement couverte : {_jours(couverte)}**"
        if isinstance(demandee, int) and couverte < demandee:
            txt += (f" — {demandee} demandés. La gateway ne conserve aucun "
                    "événement plus ancien : tout ce qui suit ne décrit que "
                    "cette profondeur-là, pas 90 jours.")
        lignes.append(txt)
    else:
        lignes.append("> - **Fenêtre couverte : profondeur inconnue** "
                      "(le document ne la porte pas).")

    if isinstance(part, (int, float)) and not isinstance(part, bool):
        sur = f" sur les {libelle}" if libelle else ""
        suite = (f" *({_pct(heritage)} sur 90 jours : héritage d'un trafic non "
                 "identifié plus ancien.)*") if heritage is not None else ""
        if part > SEUIL_NON_IDENTIFIE:
            lignes.append(
                f"> - ⚠ **{_pct(part)} des appels{sur} ne sont rattachés à aucun "
                "consommateur identifié : la dimension « qui consomme » de "
                "cette carto n'est PAS fiable.** La gateway ne renseigne pas "
                "l'application appelante ; les inventaires d'APIs et de "
                "consommateurs, eux, restent exacts." + suite)
        else:
            lignes.append(f"> - Trafic sans consommateur identifié{sur} : "
                          f"**{_pct(part)}**." + suite)
    elif libelle:
        lignes.append("> - **Part du trafic non identifié : aucun trafic servi "
                      "sur la fenêtre**, il n'y a rien à imputer.")
    else:
        lignes.append("> - **Part du trafic non identifié : inconnue** "
                      "(le document ne la porte pas).")

    lignes += [
        ">",
        "> **Cette date est la seule chose qui distingue cette page d'une page "
        "périmée.** Elle est réécrite à chaque collecte, une par jour : si elle "
        "n'est ni celle d'aujourd'hui ni celle d'hier, la collecte ne tourne "
        "plus et tout ce qui suit est faux — y compris si le dernier commit de "
        "ce dépôt est récent.",
    ]
    if page_courante != "README.md":
        lignes.append(">")
        lignes.append("> Retour à l'[accueil](README.md).")
    return "\n".join(lignes)


def _page_readme(carto, history):
    c = compteurs(carto)
    hebdo = _hebdo(history)
    precedent = history[-2] if len(history) >= 2 else None

    out = ["# Carto des API et des consommateurs", ""]
    out.append(_entete_fraicheur(carto, "README.md"))
    out += ["", "## Compteurs", ""]
    out += ["| Mesure | Valeur | Depuis la collecte précédente |",
            "|---|---:|---:|"]
    for libelle, cle in (("APIs enregistrées", "apis"),
                         ("Consommateurs enregistrés", "consumersRegistered"),
                         ("dont actifs sur la fenêtre", "consumersActive"),
                         ("Appels sur la fenêtre", "calls")):
        ecart = _delta(c[cle], precedent[cle] if precedent else None).strip()
        out.append(f"| {libelle} | {_nb(c[cle])} | {ecart or '—'} |")
    out.append(f"| Liens API ↔ consommateur | {_nb(c['edges'])} | — |")
    out.append(f"| Appelants ou APIs hors inventaire | {_nb(c['ghosts'])} | — |")
    if precedent:
        out += ["", f"La colonne d'écart compare avec la collecte du "
                    f"**{precedent['date']}** (point précédent du journal), pas "
                    f"avec la veille : si la collecte a sauté un jour, l'écart "
                    f"porte sur l'intervalle réel."]
    else:
        out += ["", "Aucune collecte précédente dans le journal : les écarts "
                    "apparaîtront au prochain passage."]

    out += ["", "## Signaux", "",
            "Chaque bloc dit **quoi en faire**. Un bloc vide est une bonne "
            "nouvelle, pas une absence de mesure.", ""]
    for titre, aide, lignes in _signaux(carto):
        out.append(f"### {titre} ({_nb(len(lignes))})")
        out.append("")
        out.append(f"*{aide}*")
        out.append("")
        out += [f"- {l}" for l in lignes] if lignes else ["Rien à signaler."]
        out.append("")

    out += ["## Les autres pages", "",
            "- [**consommateurs.md**](consommateurs.md) — l'annuaire complet : "
            "tous les consommateurs enregistrés, **y compris ceux qui n'appellent "
            "rien**, avec leurs contacts. C'est la page des campagnes de "
            "communication.",
            "- [**apis.md**](apis.md) — qui consomme quoi : une ligne par lien, "
            "avec son statut et ses volumes.",
            "- [**evolution.md**](evolution.md) — la table hebdomadaire depuis la "
            "mise en service du collecteur.",
            ""]

    out += ["## Les données, et la vue interactive", "",
            "- [`carto.json`](carto.json) — la carto complète, telle que le "
            "collecteur la produit (contrat de données version "
            f"{SCHEMA_VERSION}). Fichier lisible par une machine ; son "
            "`git diff` reste exact même quand la mise en forme des pages "
            "change.",
            "- [`history.json`](history.json) — le journal d'évolution, un point "
            "par collecte. C'est lui qui rend l'historique **durable** : il "
            "survit ici même si l'artefact de build qui le portait est purgé.",
            "- [`index.html`](index.html) — la vue interactive (tri, filtre, "
            "fiches, export CSV), **autoportante** : `carto.json` et "
            "`history.json` sont embarqués dans ce fichier, aucun serveur "
            "n'est nécessaire. La forge l'affiche comme du code source, pas "
            "comme une page : **télécharger ce seul fichier** et l'ouvrir en "
            "double-cliquant suffit.",
            ""]

    out += ["## Lire le `git diff` de ce dépôt", "",
            "C'est l'usage principal de cette publication : `git log -p "
            "apis.md` répond à « qu'est-ce qui a bougé cette semaine », avec une "
            "date et un auteur.",
            "",
            "Pour que ce soit lisible, **tout est trié par nom, jamais par "
            "volume** : une ligne qui bouge dans le diff est un lien qui est "
            "apparu, qui a disparu, ou qui a changé de statut — pas un "
            "consommateur qui a doublé son trafic et remonté dans le classement.",
            "",
            "Ces pages sont **générées** : les modifier à la main serait écrasé "
            "à la collecte suivante.",
            ""]

    if hebdo:
        out += [f"Dernière semaine du journal : **{hebdo[-1]['week']}** — "
                f"{_nb(len(history))} collecte(s) enregistrée(s) au total.", ""]
    return "\n".join(out).rstrip() + "\n"


def _page_consommateurs(carto):
    apis, consos, _, par_conso = _index(carto)
    inscrits = sorted([c for c in carto["consumers"] if not c.get("ghost")],
                      key=_cle_nom)
    fantomes = [c for c in carto["consumers"] if c.get("ghost")]

    out = ["# Annuaire des consommateurs", ""]
    out.append(_entete_fraicheur(carto, "consommateurs.md"))
    out += ["",
            f"**{_nb(len(inscrits))} consommateur(s) enregistré(s)**, dont "
            f"**{_nb(len([c for c in inscrits if not any(e['calls']['d90'] > 0 for e in par_conso.get(c['id'], []))]))} "
            "sans aucun appel sur la fenêtre**. Les consommateurs sans trafic "
            "sont ici **volontairement** : ce sont eux qu'il faut prévenir avant "
            "de déprécier une API, et aucune source de trafic ne peut les "
            "révéler.",
            ""]
    if fantomes:
        out += [f"Appelants vus dans le trafic mais absents de l'inventaire "
                f"(objet supprimé, ou appelant non identifié) : "
                f"**{_nb(len(fantomes))}**. Ils sont **exclus de cet annuaire** — "
                "on ne peut prévenir personne à leur sujet. Ils figurent dans les "
                "signaux du [README](README.md).", ""]

    out += ["| Consommateur | Équipe | Contact | APIs liées | dont actives | "
            "Appels sur la fenêtre | Enregistré le |",
            "|---|---|---|---:|---:|---:|---|"]
    for c in inscrits:
        liens = par_conso.get(c["id"], [])
        actives = [e for e in liens if e["calls"]["d90"] > 0]
        out.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            _c(c["name"]), _c(c.get("owner")), _c(c.get("contact")),
            _nb(len(liens)), _nb(len(actives)),
            _nb(sum(e["calls"]["d90"] for e in liens)),
            _jour(c.get("createdAt"))))
    if not inscrits:
        out.append("| — | — | — | — | — | — | — |")

    contacts = sorted({c["contact"] for c in inscrits if c.get("contact")})
    out += ["", "## Adresses à prévenir", ""]
    if contacts:
        out += [f"{_nb(len(contacts))} adresse(s) distincte(s), à coller dans un "
                "champ destinataires :", "", "```", "; ".join(contacts), "```", ""]
    else:
        out += ["**Aucun contact renseigné sur aucun consommateur.** Le champ "
                "existe côté gateway (`contactEmails`) mais reste vide tant que "
                "personne ne le remplit à l'enregistrement de l'application : "
                "une campagne de dépréciation n'a alors aucun destinataire. "
                "C'est un geste d'exploitation à porter au client, pas un défaut "
                "de collecte.", ""]

    out += ["## Qui appelle quoi", "",
            "Le détail lien par lien est dans [apis.md](apis.md).", ""]
    for c in inscrits:
        liens = sorted(par_conso.get(c["id"], []),
                       key=lambda e: _cle_nom(apis.get(e["apiId"], {"id": e["apiId"]})))
        if not liens:
            continue
        out.append(f"- **{_c(c['name'])}** : " + " · ".join(
            f"{_c(_nom(apis, e['apiId']))} ({_statut(e)})" for e in liens))
    out.append("")
    return "\n".join(out).rstrip() + "\n"


def _page_apis(carto):
    apis, consos, par_api, _ = _index(carto)
    w = carto.get("window") or {}
    couverte = w.get("coveredDays")

    out = ["# Qui consomme quoi", ""]
    out.append(_entete_fraicheur(carto, "apis.md"))
    out += ["",
            "Une ligne par **lien** API ↔ consommateur. Les liens sont l'**union** "
            "du déclaré et de l'observé, jamais leur intersection : un "
            "consommateur autorisé qui n'appelle pas, et un appelant qui n'a "
            "jamais été autorisé, sont l'un et l'autre invisibles pour une seule "
            "des deux sources.",
            "",
            "| Statut | Ce que ça veut dire |",
            "|---|---|",
            "| `actif` | déclaré, et vu dans le trafic |",
            "| `déclaré, inactif` | autorisé, aucun appel sur la fenêtre — "
            "**à prévenir**, pas à supprimer |",
            "| `non déclaré` | du trafic sans autorisation correspondante — "
            "**écart de gouvernance** |",
            ""]
    if isinstance(couverte, int):
        out += [f"**Les trois colonnes de volume portent leur étiquette "
                f"nominale, mais la fenêtre réellement couverte est de "
                f"{_jours(couverte)}** : aucune d'elles ne contient plus de "
                f"trafic que ça.", ""]

    out += ["| API | Version | Consommateur | Statut | 7 j | 30 j | 90 j | "
            "Dernier appel | Erreurs |",
            "|---|---|---|---|---:|---:|---:|---|---:|"]
    for e in _liens_tries(carto, apis, consos):
        a = apis.get(e["apiId"], {})
        out.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            _c(_nom(apis, e["apiId"])), _c(a.get("version")),
            _c(_nom(consos, e["consumerId"])), _statut(e),
            _nb(e["calls"]["d7"]), _nb(e["calls"]["d30"]), _nb(e["calls"]["d90"]),
            _jour(e.get("lastCall")), _pct(e["errorRate"])))
    if not carto["edges"]:
        out.append("| — | — | — | — | — | — | — | — | — |")

    out += ["", "## Inventaire des APIs", "",
            "| API | Version | Équipe | État | Consommateurs | dont actifs | "
            "Appels sur la fenêtre |",
            "|---|---|---|---|---:|---:|---:|"]
    for a in sorted(carto["apis"], key=_cle_nom):
        liens = par_api.get(a["id"], [])
        out.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            _c(a["name"]), _c(a.get("version")), _c(a.get("owner")),
            "hors inventaire" if a.get("ghost") else
            ("active" if a.get("active") else "inactive"),
            _nb(len(liens)),
            _nb(len([e for e in liens if e["calls"]["d90"] > 0])),
            _nb(sum(e["calls"]["d90"] for e in liens))))
    out.append("")
    return "\n".join(out).rstrip() + "\n"


def _page_evolution(carto, history):
    hebdo = _hebdo(history)
    retro = _retro(carto)

    out = ["# Évolution", ""]
    out.append(_entete_fraicheur(carto, "evolution.md"))
    out += ["",
            "Un point par semaine. Toutes les grandeurs sont des **stocks** "
            "mesurés à une date (y compris les appels, qui sont le total sur la "
            "fenêtre glissante) : une semaine se résume par sa **dernière** "
            "valeur, jamais par une somme.",
            "",
            "L'ordre est **chronologique croissant** : une semaine de plus est "
            "une ligne ajoutée en fin de table, donc un diff d'une seule ligne. "
            "La vue interactive, elle, affiche la plus récente en haut.",
            ""]

    if not hebdo:
        out += ["Aucun historique pour l'instant : la série se construit à partir "
                "du premier passage du collecteur.", ""]
    else:
        out += ["| Semaine | APIs | Consommateurs | dont actifs | Appels (fenêtre) |",
                "|---|---:|---:|---:|---:|"]
        for r in hebdo:
            out.append("| {} | {} | {} | {} | {} |".format(
                r["week"], _nb(r["apis"]), _nb(r["consumersRegistered"]),
                _nb(r["consumersActive"]), _nb(r["calls"])))
        out.append("")

    out += ["## Historique des APIs non reconstituable", "",
            "La gateway ne date pas ses APIs : le champ de création est absent "
            "de la réponse de liste de l'API d'administration (mesuré, voir "
            "`carto/TERRAIN.md`). La série des APIs ne peut donc démarrer qu'à "
            "la **première collecte**. Un démarrage brutal à cette date ne "
            "signifie pas que la plateforme n'avait aucune API avant : seul "
            "l'historique n'existe pas.",
            ""]

    out += ["## Série rétro-calculée — à lire avec sa réserve", ""]
    if retro:
        out += ["Reconstituée à partir de la **date d'enregistrement** des "
                "consommateurs, elle est disponible dès le premier passage. Mais "
                "c'est une **courbe de survivants** : elle ne connaît que les "
                "consommateurs existant *aujourd'hui*, donc elle **sous-estime "
                "le passé** et **ne montre aucune disparition**. Ne pas en "
                "déduire que la plateforme n'a jamais perdu de consommateur. "
                "Elle ne se compare pas terme à terme avec la table mesurée "
                "ci-dessus, et il n'en existe **aucune** pour les APIs.",
                "",
                "| Semaine | Consommateurs enregistrés (rétro-calculé) |",
                "|---|---:|"]
        out += [f"| {s} | {_nb(n)} |" for s, n in retro]
        out.append("")
    else:
        out += ["Aucun consommateur ne porte de date d'enregistrement : rien à "
                "rétro-calculer.", ""]

    out += ["## Pas de graphe ici, et pourquoi", "",
            "Aucun graphe Mermaid n'est émis : **la forge du client n'a pas été "
            "vérifiée** sur ce point, et un bloc ` ```mermaid ` non rendu "
            "s'affiche en code brut illisible au milieu de la page. La table "
            "ci-dessus dit la même chose et se lit partout, y compris dans un "
            "`git diff` en terminal. Si la forge rend Mermaid (à vérifier sur "
            "une page de test avant, pas après), le graphe s'ajoute dans "
            "`carto/render/markdown.py` — c'est le seul endroit à toucher.",
            ""]
    return "\n".join(out).rstrip() + "\n"


# --- API publique du module ----------------------------------------------

def render_pages(carto, history):
    """`carto.json` + `history.json` -> {nom de page: texte}. Fonction PURE.

    L'ordre des cles suit `PAGES`. Deux appels sur les memes entrees rendent
    des textes identiques octet pour octet — c'est teste, et c'est la seule
    propriete qui rend le `git diff` quotidien lisible.
    """
    if (carto or {}).get("schemaVersion") != SCHEMA_VERSION:
        raise VersionNonSupportee(
            "carto.json est en version de schema "
            f"{(carto or {}).get('schemaVersion')!r}, ce rendu ne sait lire que "
            f"la version {SCHEMA_VERSION}. Rien n'est ecrit : mieux vaut pas de "
            "page qu'une page mal lue — et, ici, elle serait COMMITEE. Geste : "
            "redeployer le paquet carto/ en entier (collecteur et rendus "
            "ensemble), puis relancer une collecte.")
    history = list(history or [])
    return {
        "README.md": _page_readme(carto, history),
        "consommateurs.md": _page_consommateurs(carto),
        "apis.md": _page_apis(carto),
        "evolution.md": _page_evolution(carto, history),
    }


def commit_message(carto, history):
    """Le message de commit : ce qui a CHANGE, pas « mise a jour ».

    Un depot de publication quotidienne dont tous les messages sont identiques
    rend `git log` inutilisable — or c'est justement `git log` qu'on vient
    consulter ici. Le sujet porte les trois compteurs et leur ecart, le corps
    porte la qualite de la collecte et le decompte des signaux.

    Purement deduit du document et du journal : aucune horloge, aucun appel a
    git, donc reproductible.
    """
    c = compteurs(carto)
    hist = list(history or [])
    precedent = None
    for r in reversed(hist):
        if r.get("date") != c["date"]:
            precedent = r
            break

    sujet = (f"carto {c['date']} — {_nb(c['apis'])} APIs"
             f"{_delta(c['apis'], precedent['apis'] if precedent else None)}, "
             f"{_nb(c['consumersRegistered'])} consommateurs"
             f"{_delta(c['consumersRegistered'], precedent['consumersRegistered'] if precedent else None)}, "
             f"{_nb(c['calls'])} appels"
             f"{_delta(c['calls'], precedent['calls'] if precedent else None)}")

    w = carto.get("window") or {}
    corps = []
    if precedent:
        corps.append(f"Écarts mesurés depuis la collecte du {precedent['date']}.")
    else:
        corps.append("Première collecte publiée : aucun écart à mesurer.")
    if isinstance(w.get("coveredDays"), int):
        corps.append(f"Fenêtre réellement couverte : {_jours(w['coveredDays'])} "
                     f"sur {w.get('requestedDays', '?')} demandés.")
    part, libelle, heritage = _part_jugee(carto)
    if isinstance(part, (int, float)) and not isinstance(part, bool):
        alerte = " — dimension consommateur NON fiable" if part > SEUIL_NON_IDENTIFIE else ""
        sur = f" ({libelle})" if libelle else ""
        suite = f" Héritage : {_pct(heritage)} sur 90 jours." if heritage is not None else ""
        corps.append(f"Trafic sans consommateur identifié{sur} : "
                     f"{_pct(part)}{alerte}.{suite}")

    corps.append("")
    corps.append("Signaux :")
    for titre, _aide, lignes in _signaux(carto):
        corps.append(f"- {titre} : {_nb(len(lignes))}")

    return sujet + "\n\n" + "\n".join(corps) + "\n"
