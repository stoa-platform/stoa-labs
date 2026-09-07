#!/usr/bin/env bash
# scripts/lib/generate-choices.sh — génère les fragments <string>…</string>
# des listes déroulantes Jenkins (équipes, APIs) depuis l'état RÉEL sur
# GITEA MAIN — jamais depuis le worktree local (qui peut être en avance ou en
# retard sur ce qui est réellement mergé). À SOURCER, jamais exécuté seul.
#
# generate_choices_teams <env> : une <string>…</string> par équipe déclarée
#   dans ansible/providers.<env>.yml.
# generate_choices_teams_raw / generate_choices_apis_raw <env> : les MÊMES
#   listes, une VALEUR brute par ligne (A0 : formulaire posé par le Jenkinsfile).
# generate_choices_apis  <env> : une <string>nom@version</string> par API
#   trouvée dans clients/*/apis/*.publish.yml (dépôt plateforme, squelettes
#   déjà onboardés) UNION apis/*.publish.yml des dépôts d'équipe déclarés
#   dans providers.<env>.yml (repo: "" toléré — rien à balayer, pas une erreur).
#
# FAIL-CLOSED (non négociable — le brief de la Task 3) :
#   - Gitea injoignable, providers.<env>.yml absent, ou YAML cassé -> ÉCHEC
#     (return 1, message explicite sur stderr) AVANT que l'appelant ne poste
#     quoi que ce soit à Jenkins.
#   - Liste finale vide -> ÉCHEC aussi. Zéro équipe déclarée = lab pas amorcé,
#     pas un état posable ; un formulaire aux choix vides ne doit JAMAIS
#     partir en silence.
#   - Un dépôt d'équipe DÉCLARÉ mais introuvable sur Gitea (T5/T6 n'ont pas
#     encore livré la chaîne producteur, donc la plupart n'existent pas
#     encore) est TOLÉRÉ : averti sur stderr, ignoré pour cette liste — ce
#     n'est pas la même chose qu'une source cassée. Un fichier
#     apis/*.publish.yml PRÉSENT mais illisible/malformé, lui, EST une
#     source cassée (corruption réelle) et fait échouer tout l'appel : la
#     distinction est délibérée (cf. task-3-report.md).
#
# Entrées (env) :
#   FORGE_SECRET le secret de la forge : jeton OU mot de passe d'un couple
#                (alias historique : GITEA_TOKEN — toujours honoré)
#   FORGE_USER   l'utilisateur du couple (alias : GIT_USER ; défaut « x », que
#                seul Gitea accepte — GitLab et Bitbucket rendent 401)
#   GIT_HOST     défaut http://gitea:3000 (toute forge servant du git HTTP :
#                le clone n'utilise que git, pas l'API de la forge — le refus
#                s'appelle GIT_UNREACHABLE et cite la sortie de git).
#                UN « @ » DANS GIT_HOST EST UN REFUS — RÈGLE UNIQUE, sans
#                exception d'apparence : GIT_HOST_PORTE_IDENTIFIANTS, rendu
#                avant tout appel réseau. SEULE EXCEPTION, lue au PREMIER
#                CARACTÈRE : un GIT_HOST qui commence par « / », « ./ », « ../ »
#                ou « ~ » est un CHEMIN LOCAL (les harnais de ce dépôt clonent
#                depuis /tmp). Un identifiant se pose dans FORGE_USER +
#                FORGE_SECRET ; l'encadré « UN « @ » DANS GIT_HOST » plus bas
#                dit pourquoi ce n'est plus une affaire de motif.
#                ⚠ INCOHÉRENCE CONNUE, À L'ÉCHELLE DU DÉPÔT — À NE PAS PRENDRE
#                POUR UNE PROTECTION GÉNÉRALE (constat 2026-09-08, NON traité
#                ici : le périmètre de cette passe est ce seul fichier).
#                generate-choices.sh est le SEUL fichier du dépôt à refuser un
#                GIT_HOST porteur d'un « @ » : `grep -rl GIT_HOST_PORTE_IDENTIFIANTS
#                scripts/ ansible/` ne rend que cette lib et son harnais — la
#                mesure est celle d'une ABSENCE, pas une impression. Les autres
#                consommateurs de GIT_HOST l'ACCEPTENT tel quel ; relevé ligne à
#                ligne : provision-request.sh compose GIT_BASE_URL depuis
#                GIT_HOST (l. 397), le passe à `git clone` EN ARGV (l. 416-417,
#                donc visible dans `ps`) et cite GIT_HOST NON EXPURGÉ dans son
#                échec de clone (l. 418). Même forme dans api-request.sh
#                (l. 258, 299, 388), api-promote-request.sh (l. 239),
#                api-promote-export.sh (l. 129, 268) et app-rollback-request.sh
#                (l. 64-65, 177). Conclusion à tenir : dans un run Jenkins, un
#                secret logé dans GIT_HOST peut fuir par un AUTRE script que
#                celui-ci ; le refus ci-dessus protège CE chemin de code, pas la
#                plateforme. NON TRAITÉ ICI — le périmètre de la passe 7 est
#                generate-choices.sh et son harnais.
#   GIT_HOST_USERINFO_TOLERE
#                =1 (et rien d'autre ; AUCUN défaut) : le refus ci-dessus
#                redevient un AVERTISSEMENT nommé
#                (GIT_HOST_PORTE_IDENTIFIANTS_TOLERE) et le run continue. La
#                protection ne repose alors QUE sur l'expurgation, qui est un
#                filet et non une garantie.
#   GIT_REPO     défaut ci/stoa-labs (dépôt plateforme, porte providers.<env>.yml)
#
# LE SECRET : CE QUI EST VRAI (2026-09-07 ter — la phrase d'avant était FAUSSE
# sur deux points, et trois passes de revue l'ont relue sans la mesurer). Elle
# disait « FORGE_SECRET requis (${:?}) », or :
#   - il n'y a AUCUN « ${:?} » sur le secret dans ce fichier, et il ne doit pas
#     y en avoir (cf. ENV_REQUIS plus bas : un ${VAR:?} abat le shell appelant
#     au lieu de rendre un refus). La garde est un test explicite qui rend le
#     refus NOMMÉ « SECRET_FORGE_REQUIS », en tête de ligne, sur stderr ;
#   - il n'est pas « requis » tout court : il l'est SUR LE CHEMIN DE CLONE,
#     et là seulement. MESURÉ : avec GC_PLATFORM_DIR posé et aucun dépôt
#     d'équipe déclaré, aucun secret n'est lu et la liste sort (rc 0). Chaque
#     dépôt d'équipe DÉCLARÉ, lui, est cloné : sans secret, son clone échoue et
#     devient l'avertissement « ignoré pour cette liste — SECRET_FORGE_REQUIS ».
# CE QUI RESTE VRAI de la phrase d'avant : jamais en argv — le header Basic est
# injecté par GIT_CONFIG_COUNT/KEY/VALUE (même motif que team-apply.sh et
# team-request.sh pour leurs push, symétrique en lecture ici), vérifié en direct
# par sondage ps -ww dans ce dépôt.
#
# Sortie : sur stdout, une ligne "<string>valeur échappée</string>" par entrée
# (ordre non garanti pour generate_choices_apis — trié). Rien d'autre sur
# stdout : les diagnostics vont sur stderr, pour un usage sûr en `X=$(fn env)`.
#
# SIGNAL DE TOLÉRANCE (revue round 1) : generate_choices_apis émet, sur
# stderr, un marqueur explicite — motif marqueur de la classe du palier 2 :
#   CHOICES_SKIPPED_REPOS=<n>
#
# OÙ LE CHERCHER — AUCUNE POSITION N'EST PROMISE (2026-09-07, réécrit).
# Ce contrat a promis DEUX positions successives, et les deux étaient fausses.
# Il a d'abord annoncé le marqueur en DERNIÈRE ligne ; corrigé, il a affirmé
# sans réserve que « la DERNIÈRE ligne de stderr est le refus, pas le marqueur »
# — faux à son tour, sur les deux chemins PUBLISH_YML_PARSE, où le refus est
# émis par _gc_collect_publish_yml AVANT que la fonction n'émette le marqueur.
# MESURÉ, chemin par chemin :
#   APIS_EMPTY         → dernière ligne = le REFUS   (le marqueur le précède)
#   PUBLISH_YML_PARSE  → dernière ligne = le MARQUEUR (le refus le précède)
# La position N'EST DONC PAS un contrat, dans aucun des deux sens. Ce qui EST
# promis — et gardé par une épreuve COMPORTEMENTALE, qui observe stderr et non
# le texte de ce commentaire (test-generate-choices.sh, § 16d) :
#   - le marqueur est SEUL sur sa ligne          → grep ANCRÉ '^CHOICES_SKIPPED_REPOS='
#   - l'identifiant de refus est EN TÊTE de ligne → grep ANCRÉ '^APIS_EMPTY : '
# Un intégrateur qui code sur `tail -1 | grep` lit donc autre chose SELON LE
# CHEMIN : c'est le grep ANCRÉ qu'il faut, dans les deux cas.
# LES DEUX CONSOMMATEURS EN PLACE, exactement (vérifié, pas supposé — la version
# précédente de ce paragraphe leur prêtait le grep ancré, qu'ils n'utilisent
# pas) : team-apply.sh:407 et team-publish.sh:470 font
#   grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$log" | tail -1 | cut -d= -f2
# — `-o` EXTRAIT le jeton où qu'il soit dans le log, et le `tail` départage
# PLUSIEURS marqueurs d'un MÊME log (une re-pose en produit un par appel de la
# fonction), jamais une position dans stderr. Cette forme est donc, elle aussi,
# indépendante de la position : elle reste valide et n'est pas touchée. Pour un
# consommateur NEUF, préférer le grep ancré : le marqueur est seul sur sa ligne,
# et c'est cela qui est promis.
#
# <n> = nombre de dépôts d'équipe DÉCLARÉS mais introuvables sur Gitea,
# tolérés (cf. FAIL-CLOSED plus haut). ÉMIS SUR TOUTE SORTIE de
# generate_choices_apis_raw — le succès ET chacun de ses NEUF chemins d'échec
# (ENV_REQUIS, GIT_HOST_PORTE_IDENTIFIANTS, MKTEMP, GIT_UNREACHABLE,
# PROVIDERS_MISSING, PROVIDERS_PARSE, les deux PUBLISH_YML_PARSE, APIS_EMPTY) —
# y compris n=0, pour que l'absence du
# marqueur n'ait qu'UNE seule lecture : generate_choices_apis_raw n'a pas été
# appelée de ce run (ex. aucun job posé n'a le placeholder APIS). Un SEUL point
# d'émission dans le code (_gc_emit_marker), pour que cette phrase ne puisse
# pas redevenir fausse par une recopie oubliée sur un chemin neuf ; une épreuve
# balaie les neuf chemins un par un. generate_choices_teams_raw, elle, n'émet
# JAMAIS ce marqueur — c'est ce qui donne son sens à « absent ».
# 2026-09-07 (ter) : ce compte disait SEPT, et la § 17 en balayait sept — la
# garde d'argument (ENV_REQUIS, ci-dessous) était une huitième sortie, muette.
# 2026-09-07 (quater) : il disait HUIT, et la porte GIT_HOST (I1, ci-dessous)
# en est une NEUVIÈME. Une phrase ABSOLUE (« TOUS les chemins ») se démontre en
# énumérant, et une énumération incomplète la rend fausse sans que rien ne
# rougisse — deux fois de suite, ici, le compte a été le maillon oublié.
# VOLONTAIREMENT sur stderr, jamais
# stdout : stdout devient tel quel le fragment XML inséré par `sed r` dans un
# job Jenkins — y mêler une ligne "CHOICES_SKIPPED_REPOS=…" casserait le XML
# posé. C'est ce marqueur que setup-team-onboard-jobs.sh laisse remonter
# (stderr non capturé par `$(...)`) et que team-apply.sh grep dans son log de
# re-pose MÊME SUR SUCCÈS — sans lui, une re-pose réussie pouvait cacher en
# silence une équipe tolérée/sautée (cf. task-3-report.md, round 1).
#
# AUTO-DIAGNOSTIC (2026-09-07, incident client : APIS_EMPTY sur un déploiement
# où les DEUX dépôts d'équipe déclarés étaient illisibles). Le log Jenkins ne
# portait que « dépôt d'équipe X illisible sur main » ×2 puis APIS_EMPTY : ni
# l'URL tentée, ni la branche réelle, ni la sortie de git, ni le chemin balayé
# — 401, 404, branche absente, proxy et TLS rendaient le MÊME texte, et un
# clients/ ABSENT était indistinguable d'un clients/ vide. C'est l'incident du
# 2026-09-03 (cause avalée) rejoué sur l'autre branche du même fichier : le
# correctif d'alors n'avait touché QUE le refus du dépôt plateforme. Depuis :
#   - l'avertissement d'un dépôt d'équipe cite l'URL EXPURGÉE, la branche
#     ${GIT_BASE:-main} (plus le mot « main » en dur, qui pouvait mentir) et
#     la sortie de git (_GC_CLONE_ERR, déjà expurgée par _gc_clone) ;
#   - APIS_EMPTY nomme le chemin balayé, son état, le motif find, le fichier
#     providers lu, et les comptes déclaré/cloné/sauté ;
#   - APIS_EMPTY ne renvoie vers « les dépôts d'équipe avertis ci-dessus » QUE
#     s'il en a réellement averti (skipped > 0). La clause était inconditionnelle
#     et mentait donc dans les deux cas fréquents — zéro dépôt déclaré, ou tous
#     clonés : elle envoyait l'opérateur réparer des dépôts dont aucun message
#     ne parlait (c'est la classe de défaut que ce fichier prétend abolir) ;
#   - le marqueur CHOICES_SKIPPED_REPOS est émis sur TOUTE SORTIE de
#     generate_choices_apis_raw (cf. SIGNAL DE TOLÉRANCE ci-dessus) : il ne
#     l'était d'abord qu'après le `return 1` d'APIS_EMPTY — donc jamais quand il
#     compte —, puis sur trois chemins seulement (APIS_EMPTY + les deux
#     PUBLISH_YML_PARSE) alors que l'en-tête en promettait SEPT.
# Règle tenue : on ENRICHIT les messages, on ne renomme aucun identifiant de
# refus (les greps en place — team-apply.sh, team-publish.sh — sont intacts).

# _gc_escape <valeur> — échappe & et < (défense en profondeur : la regex
# ^[a-z0-9][a-z0-9-]{1,30}$ de team-request.sh interdit déjà ces caractères
# dans un nom d'équipe, et le contrat apim_publish_api restreint name/version
# de la même façon côté producteur — mais un fragment XML ne doit JAMAIS
# dépendre UNIQUEMENT d'une garde en amont).
_gc_escape(){
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  printf '%s' "$s"
}

# _gc_clone <repo_fullname> <dest> — clone superficiel (branche main) de
# <repo_fullname> depuis GIT_HOST, EN LECTURE, dans <dest> (déjà créé, vide).
# Le token est injecté en HEADER Basic via GIT_CONFIG_COUNT/KEY/VALUE, jamais
# dans l'URL/argv (motif éprouvé de team-apply.sh — vérifié en direct par
# sondage ps -ww dans ce dépôt, jamais recomposé).
# _GC_CLONE_ERR : la DERNIÈRE erreur de git, expurgée, publiée par _gc_clone.
# Avant (2026-09-03), `2>/dev/null` avalait la cause : un déploiement client ne
# pouvait pas distinguer un hôte injoignable d'un jeton refusé, d'une branche
# `main` absente ou d'un dépôt privé — tous rendus par le même refus muet.
_GC_CLONE_ERR=""
# Disposition du dépôt (2026-09-03) : le préfixe du livrable n'est plus écrit en
# dur ici. La lib voisine le normalise (sentinelle « . », tiret nu) ; elle est
# localisée par le chemin de CE fichier, la lib pouvant être sourcée depuis
# n'importe quel répertoire de travail.
# shellcheck source=scripts/lib/repo-layout.sh
# (cette lib est TOUJOURS sourcée : `return` est la seule sortie correcte ici)
. "${BASH_SOURCE[0]%/*}/repo-layout.sh" || { echo "LIB_ABSENTE : repo-layout.sh (voisine de generate-choices.sh)" >&2; return 1; }
repo_layout_init || { echo "GIT_SUBDIR_INVALIDE : voir scripts/lib/repo-layout.sh" >&2; return 1; }
# ─────────────────────────────────────────────────────────────────────────────
# UN « @ » DANS GIT_HOST : UN REFUS. RÈGLE UNIQUE, SANS INTELLIGENCE.
# (2026-09-07 quinquies — CINQUIÈME passe sur la MÊME fuite, et la première qui
# ne raffine pas la frontière : elle la SUPPRIME.)
#
# CINQ passes ont tenté de fermer cette fuite par un MOTIF. Chacune a fermé la
# forme qu'elle visait et en a laissé une voisine, SUITE VERTE À CHAQUE FOIS :
#   1. « / » et « @ » après « :// »   (la classe [^/@[:space:]]* s'y arrêtait)
#   2. la forme scp-like, sans schéma (les deux règles étaient ancrées sur « :// »)
#   3. le « / » DANS le secret        (la frontière était recopiée en deux langues)
#   4. l'ESPACE, la TABULATION, le SAUT DE LIGNE (les règles PAR MOTIF, jouées
#      avant la règle littérale, détruisaient le littéral qu'elle cherchait)
#   5. une AUTORITÉ QUI RESSEMBLE À UN HÔTE une fois tronquée au premier « / ».
#      MESURÉ contre la passe 5, sur ce fichier, avant ce correctif :
#        GIT_HOST='http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x'
#      ⇒ rc 0, la liste sort, « Xk9pQ » EN CLAIR 2 fois par run, ni refus ni
#      avertissement : l'autorité « svc:4821 » satisfaisait la regex d'hôte de
#      la passe 5, qui en concluait « le « @ » est dans le CHEMIN ». Le bouclier
#      ajouté au même moment (« protéger de l'expurgation la valeur déclarée
#      légitime ») protégeait ACTIVEMENT ce secret des règles par motif.
#
# LA CAUSE N'EST AUCUNE DE CES CINQ FORMES : c'est la PRÉMISSE. Décider par
# motif si un « @ » appartient à un userinfo ou à un chemin n'est pas soluble —
# un secret a le droit de contenir « / », « @ », « : », un blanc, et de
# RESSEMBLER à un hôte. La passe 5 demandait une détection « large et
# fail-closed, SAUF les formes qui ne sont pas des identités » : cette EXCEPTION
# était le trou.
#
# LA RÈGLE, DÉSORMAIS, TIENT EN UNE LIGNE :
#     GIT_HOST contient un « @ »  ⇒  REFUS.
# Aucune analyse d'autorité, aucune regex d'hôte, aucun « sauf si ça ressemble
# à ». La SEULE exception est SYNTAXIQUE et se lit au PREMIER CARACTÈRE : un
# GIT_HOST qui commence par « / », « ./ », « ../ » ou « ~ » est un CHEMIN LOCAL
# (les harnais de ce dépôt clonent depuis /tmp ; un client peut servir un dépôt
# de fichiers ; un répertoire Jenkins concurrent porte un « @ », « …/job@2 »).
# Elle ne regarde PAS ce qui suit — elle n'a donc aucune frontière à deviner.
# CE QUE CETTE JUSTIFICATION NE COUVRE PAS, ET LA PHRASE D'AVANT LE LAISSAIT
# CROIRE : elle citait « ws@2 », l'écriture COURTE du répertoire Jenkins. Or
# « ws@2 » ne commence par AUCUNE des quatre formes exemptées. MESURÉ, verdict
# par écriture :
#   /var/jenkins_home/workspace/job@2  → pas une identité (exempté)
#   ./ws@2   → exempté          ~/ws@2 → exempté
#   ws@2     → REFUSÉ           workspace/ws@2 → REFUSÉ      job@2 → REFUSÉ
# Autrement dit : seules les écritures ABSOLUES ou explicitement préfixées
# « ./ », « ../ », « ~ » sont exemptées. Un GIT_HOST relatif nu qui porte un
# « @ » est refusé — c'est voulu (on ne devine pas « ça ressemble à un chemin »),
# et le remède est de l'écrire « ./ws@2 » ou en absolu.
#
# CONSÉQUENCE ASSUMÉE, ET C'EST UN ARBITRAGE, PAS UN OUBLI : une URL légitime
# dont le CHEMIN porte un « @ » (un suffixe de version, « …/depot@v1 ») devient
# un REFUS. On accepte de refuser une forme rare et RÉPARABLE plutôt que de
# laisser fuir un secret ; le refus NOMME ce cas et son remède, pour que
# l'opérateur qui le rencontre comprenne en une lecture.
# PORTE DE SORTIE, explicite et bruyante : GIT_HOST_USERINFO_TOLERE=1 rend au
# refus le statut d'AVERTISSEMENT (GIT_HOST_PORTE_IDENTIFIANTS_TOLERE) et laisse
# le run continuer. Le knob n'a AUCUN défaut : non posé ⇒ refus.
# L'EXPURGATION RESTE, en filet — plus jamais comme LA garantie : pour le run
# toléré, et pour un secret qui ne vient PAS de GIT_HOST (URL de proxy réémise
# par git, URL de sous-module).
# ─────────────────────────────────────────────────────────────────────────────

# DEUX QUESTIONS, DEUX FONCTIONS — LA SIXIÈME FUITE, ET SA CAUSE STRUCTURELLE.
# (2026-09-08, passe 7. Les passes 1 à 5 raffinaient un MOTIF ; la passe 6 a
# supprimé la frontière du REFUS mais a laissé UNE SEULE fonction répondre à
# DEUX questions. C'est cette confusion-là qui a fui la sixième fois.)
#
# Les deux questions ne sont pas la même :
#     Q1  « faut-il REFUSER ce GIT_HOST ? »
#     Q2  « faut-il EXPURGER ce littéral des messages ? »
# L'exception de CHEMIN (« / », « ./ », « ../ », « ~ ») est JUSTE pour Q1 : les
# harnais de ce dépôt clonent depuis /tmp et ne doivent pas être refusés. Elle
# est FAUSSE pour Q2 : un GIT_HOST de forme CHEMIN peut parfaitement porter un
# secret, et le masquer ne coûte qu'un peu de lisibilité.
# MESURÉ sur la version d'avant (fichier livré, suite VERTE à 192/192), par
# `_gc_redact "$GIT_HOST"` — la valeur ressort TELLE QUELLE, non masquée :
#   GIT_HOST='~u:SEC/RETQUIRESTE@hote-zz.invalid:scm'  ⇒ EN CLAIR
#   GIT_HOST='./u:SECRET123@forge'                     ⇒ EN CLAIR
#   GIT_HOST='../u:SECRET123@forge'                    ⇒ EN CLAIR
#   GIT_HOST='/u:SECRET123@forge'                      ⇒ EN CLAIR
# et, sur un run complet de generate_choices_apis_raw, 3 LIGNES de stderr citent
# le secret (cf. le compte exact dans « CE QUE CE FICHIER TIENT », plus bas).
# — rc 0, ni refus ni avertissement, knob éteint. _gc_redact s'ouvrait sur
# `_gc_host_userinfo`, qui rendait « pas une identité » pour ces quatre formes :
# les règles 3 et 3bis étaient SAUTÉES, et les règles par motif ne suffisaient
# pas (cf. la mesure dans « CE QUE CE FICHIER TIENT », plus bas — le « / » qui
# les arrête n'est pas toujours celui du secret).
#
# LE GESTE, ET IL EST STRUCTUREL : les deux questions sont désormais posées à
# deux fonctions distinctes.
#   _gc_host_userinfo   — Q1, LE VERDICT. Garde l'exception de chemin. Ne rend
#                         qu'un rc ; ne touche PLUS _GC_HOST_UI.
#   _gc_host_ui_extract — Q2, L'EXTRACTION. AUCUNE exception : elle extrait
#                         toujours, quelle que soit la FORME de GIT_HOST.
# _gc_redact n'appelle QUE la seconde, et ne consulte PLUS jamais la notion de
# « chemin ». Si une passe future rajoute un `case … /*|./*|../*|'~'*` dans
# _gc_host_ui_extract ou dans _gc_redact, elle rouvre exactement cette fuite.
#
# COROLLAIRE ASSUMÉ, MESURÉ, ET C'EST LE PRIX : un CHEMIN LOCAL qui contient un
# « @ » voit désormais tout ce qui précède son DERNIER « @ » masqué dans les
# messages de cette lib. Mesuré : « /tmp/gencho.XXXX/forge@local/depots/a.git »
# devient « <identifiants masqués>@local/depots/a.git » — le diagnostic garde
# l'hôte/le suffixe APRÈS le « @ » et perd le préfixe. C'est modeste, et cela
# vaut mieux qu'un secret en clair. Gardé par la § 22 (cas 19) et la § 22bis.

# _gc_host_userinfo — Q1, LE VERDICT, et RIEN D'AUTRE : un « @ », sauf CHEMIN
# LOCAL. Deux `case`, et rien de plus. Toute ligne ajoutée ici pour « mieux »
# classer une forme (regex d'hôte, découpe d'autorité, « sauf si… ») RECRÉERAIT
# le défaut des cinq premières passes — c'est la seule chose que ce fichier
# demande de ne pas faire.
# Le refus (_gc_gate_host_userinfo) et l'avertissement toléré LISENT cette
# fonction — aucun ne la recopie. La divergence entre deux copies de la même
# règle est EXACTEMENT le défaut de la passe 3. _gc_redact, lui, ne l'appelle
# PLUS : c'est le correctif de la passe 7.
#   rc 0 : REFUS (avertissement sous le knob).
#   rc 1 : aucun « @ », ou un CHEMIN LOCAL.
_gc_host_userinfo(){
  local h="${GIT_HOST:-}"
  case "$h" in *@*) : ;; *) return 1 ;; esac       # aucun « @ » : rien à décider
  case "$h" in /*|./*|../*|'~'*) return 1 ;; esac  # CHEMIN LOCAL : lu au PREMIER caractère
  return 0
}

# _gc_host_ui_extract — Q2, L'EXTRACTION PURE du littéral à masquer
# (_GC_HOST_UI). ELLE NE DÉCIDE RIEN et n'a AUCUNE exception : elle extrait pour
# toute valeur de GIT_HOST portant un « @ », chemin compris. Le schéma est
# retiré s'il y en a un, et le littéral court jusqu'au DERNIER « @ ». Si le
# « @ » est AVANT le schéma (forme absurde, mais possible), on repart de la
# valeur entière : mieux vaut un littéral large qu'un littéral vide, qui ne
# masquerait rien.
#   rc 0 : _GC_HOST_UI reçoit le littéral, éventuellement VIDE
#          (« http://@forge » : un « @ » de FORME, rien à masquer).
#   rc 1 : aucun « @ » dans GIT_HOST — il n'y a rien à extraire.
#
# POURQUOI UNE GLOBALE ET NON UN `printf` LU EN `$( )` : une substitution de
# commande AVALE les sauts de ligne de FIN. Un secret terminé par un saut de
# ligne perdait donc son littéral, et la règle 3 ne matchait plus rien. Mesuré :
#   GIT_HOST=$'http://u:CAN\n@forge' ⇒ « $(…) » rend « u:CAN », pas « u:CAN\n ».
_GC_HOST_UI=""
_gc_host_ui_extract(){
  _GC_HOST_UI=""
  local h="${GIT_HOST:-}" corps
  case "$h" in *@*) : ;; *) return 1 ;; esac
  case "$h" in *://*) corps="${h#*://}" ;; *) corps="$h" ;; esac
  case "$corps" in *@*) : ;; *) corps="$h" ;; esac
  _GC_HOST_UI="${corps%@*}"
  return 0
}

# _gc_gate_host_userinfo — LE REFUS. Appelé en TÊTE des deux entrées publiques :
# avant le premier mktemp, avant le premier clone, avant tout message citant
# l'hôte. rc 1 ⇒ l'appelant rend son refus sans rien tenter.
# Le message ne cite JAMAIS la valeur : il décrit la FORME et donne le remède.
# Il dit « un « @ » » et non « un userinfo », parce qu'affirmer l'identifiant
# serait affirmer ce qui n'a pas forcément eu lieu — et il NOMME les DEUX cas
# qui l'amènent, dont celui, assumé, d'une URL légitime à « @ » dans le chemin :
# un opérateur qui rencontre ce refus doit comprendre en UNE lecture lequel des
# deux est le sien.
# L'AVERTISSEMENT toléré n'est émis qu'UNE FOIS par processus (_GC_HOST_WARNED) ;
# le REFUS, lui, sort à chaque appel — il est la valeur de retour de l'appel.
_GC_HOST_WARNED=""
_gc_gate_host_userinfo(){
  _gc_host_userinfo || return 0
  if [ "${GIT_HOST_USERINFO_TOLERE:-}" = "1" ]; then
    [ -z "${_GC_HOST_WARNED:-}" ] || return 0
    _GC_HOST_WARNED=1
    echo "GIT_HOST_PORTE_IDENTIFIANTS_TOLERE : GIT_HOST contient un « @ » — refusé par défaut (règle unique : tout « @ », sauf un GIT_HOST qui COMMENCE par « / », « ./ », « ../ » ou « ~ », qui est un chemin local). GIT_HOST_USERINFO_TOLERE=1 est posé : AVERTISSEMENT au lieu du refus, la lecture continue. LA PROTECTION NE REPOSE PLUS QUE SUR L'EXPURGATION des messages de cette lib, qui est un FILET et non une garantie — git, un proxy, un sous-module ou un journal tiers peuvent réémettre le secret EN CLAIR, et Jenkins ne masque pas GIT_HOST (c'est une valeur d'environment{}, pas un credential). REMÈDE DURABLE : si un identifiant est posé dans GIT_HOST, le retirer et le poser dans FORGE_USER + FORGE_SECRET (alias historique GITEA_TOKEN) ; si c'est le CHEMIN d'une URL par ailleurs légitime qui porte le « @ » (un suffixe de version, « …/depot@v1 »), servir le dépôt sous un chemin sans « @ »." >&2
    return 0
  fi
  echo "GIT_HOST_PORTE_IDENTIFIANTS : GIT_HOST contient un « @ ». RÈGLE UNIQUE, sans exception d'apparence : tout « @ » dans GIT_HOST est refusé. Décider par motif si un « @ » sépare une identité ou appartient à un chemin n'est pas soluble — cinq motifs successifs ont chacun laissé fuir un secret sur une suite verte. SEULE EXCEPTION, lue au PREMIER caractère : un GIT_HOST qui commence par « / », « ./ », « ../ » ou « ~ » est un CHEMIN LOCAL et n'est jamais refusé. REFUS : aucun accès à la forge n'a été tenté, et aucun message ÉMIS PAR CETTE LIB ne cite l'hôte — pas « aucun message du run » : cette lib ne contrôle ni git, ni un proxy, ni Jenkins, ni les AUTRES scripts du même build, dont plusieurs (provision-request.sh, api-request.sh, api-promote-request.sh, api-promote-export.sh, app-rollback-request.sh) acceptent GIT_HOST tel quel, le passent à git en argv et le citent NON EXPURGÉ dans leurs erreurs. DEUX CAS, DEUX REMÈDES. (1) UN IDENTIFIANT EST POSÉ DANS GIT_HOST (http://utilisateur:secret@hôte, ou scp-like utilisateur@hôte:chemin) : le retirer de GIT_HOST et le poser dans FORGE_USER + FORGE_SECRET (alias historique GITEA_TOKEN). Un secret laissé dans GIT_HOST ressort EN CLAIR par git, un proxy, un sous-module ou le log de build, et Jenkins ne le masque pas (GIT_HOST est une valeur d'environment{}, pas un credential) : l'expurgation de cette lib ne couvre que ses PROPRES messages. (2) L'URL EST LÉGITIME ET C'EST SON CHEMIN QUI PORTE LE « @ » (un suffixe de version, « …/depot@v1 ») : ce refus-là est ASSUMÉ — refuser une forme rare et réparable coûte moins qu'un secret dans un journal ; remède, servir le dépôt sous un chemin sans « @ », ou prendre la porte de sortie ci-dessous. PORTE DE SORTIE, dans les deux cas : poser GIT_HOST_USERINFO_TOLERE=1 — le refus redevient un avertissement, et la protection ne repose alors QUE sur l'expurgation, qui est un filet et non une garantie." >&2
  return 1
}

# _gc_redact <texte> — LE FILET ; ce n'est PLUS la garantie (cf. l'encadré
# ci-dessus). Retire la partie userinfo d'une URL, dans la sortie de git comme
# dans GIT_HOST lui-même. QUATRE règles (3, 3bis, 1, 2), et leur ORDRE est
# mesuré :
#   RÈGLE 3, EN PREMIER, LITTÉRALE : la lib CONNAÎT le littéral de son propre
#     GIT_HOST (_gc_host_ui_extract — L'EXTRACTION, jamais le VERDICT : cf.
#     l'encadré « DEUX QUESTIONS, DEUX FONCTIONS ») — inutile de le deviner.
#     Tout ce qui précède le DERNIER « @ » de GIT_HOST est remplacé, AVEC son
#     « @ », partout où il apparaît, QUELLE QUE SOIT LA FORME de GIT_HOST —
#     chemin local compris. Le « @ » fait partie du littéral : sans lui, un
#     GIT_HOST « git@forge:scm » masquerait le mot « git » dans toute la sortie
#     de git. Elle est EXACTE, pas gloutonne : elle ne masque QUE la valeur
#     configurée, jamais un motif — un hôte légitime reste donc lisible au
#     diagnostic.
#   RÈGLE 3bis, LITTÉRALE elle aussi : chaque SEGMENT du mot de passe (le
#     userinfo après son premier « : »), découpé sur les séparateurs d'URL
#     « / : @ » et les blancs, à partir de 4 caractères. Elle rattrape le
#     transport qui n'en réémet qu'un morceau — mesurée sur ssh, cf. « CE QUI
#     RESTE NON COUVERT » plus bas. Ce n'est pas une devinette de plus : on ne
#     cherche aucune frontière, on masque les morceaux d'une valeur CONNUE.
#   RÈGLE 1, scp-like PAR MOTIF : dans un jeton délimité par des blancs et sans
#     « / » avant son « @ », tout ce qui précède le DERNIER « @ » est masqué.
#   RÈGLE 2, « :// » PAR MOTIF, gloutonne jusqu'au dernier « @ » du jeton.
# Les règles 1 et 2 ne connaissent pas GIT_HOST : elles sont là pour un secret
# qui vient d'AILLEURS (proxy, sous-module) et n'ont donc pas de littéral.
#
# POURQUOI LA RÈGLE 3 EST PASSÉE EN PREMIER — c'est le défaut mesuré de la
# passe 4, et il ne tenait PAS à l'extraction (elle était juste) mais à
# l'ORDRE : jouées d'abord, les règles 1 et 2 DÉTRUISENT le littéral que la
# règle 3 cherche ensuite. MESURÉ sur le worktree d'avant, 3 occurrences EN
# CLAIR par run sur le chemin des dépôts d'équipe :
#   GIT_HOST='http://u:CANARI AVEC ESPACE@forge.bdf.fr/x'
#     ⇒ « http://u:CANARI AVEC <identifiants masqués>@forge.bdf.fr/x »
#       (la règle 1 mord sur « ESPACE@ » ; le littéral n'existe plus)
#   GIT_HOST=$'http://u:CAN\nARI@forge.bdf.fr/x'
#     ⇒ « http://u:CAN␤<identifiants masqués>@forge.bdf.fr/x »
#       (sed travaille LIGNE à ligne ; GIT_HOST est UNE variable, pas un flux)
#   GIT_HOST=$'http://u:CAN\tARI@forge.bdf.fr/x'  ⇒ même fuite (tabulation)
# La règle 3 posée d'abord, le littéral est intact et le masquage est exact.
#
# LE MARQUEUR EST PROTÉGÉ DES RÈGLES PAR MOTIF, ET _gc_redact EST DÉSORMAIS
# IDEMPOTENTE (elle ne l'était pas, et c'était une limite assumée). Son texte
# de remplacement, « <identifiants masqués>@ », porte une espace et un « @ » :
# jouées après lui, les règles 1 et 2 remordaient dessus et rendaient
# « http://<identifiants <identifiants masqués>@hote ». Le marqueur est donc
# converti en SENTINELLE (l'octet \001, qui n'apparaît dans aucun message de
# cette lib) avant les deux sed, et restauré après. Conséquence GARDÉE par
# épreuve : _gc_redact "$(_gc_redact X)" = _gc_redact X.
#
# LA FRONTIÈRE NE PROTÈGE PLUS RIEN DE L'EXPURGATION (2026-09-07 quinquies).
# La passe 5 avait ajouté ici un BOUCLIER : quand la frontière répondait « ce
# GIT_HOST ne porte PAS d'identité », sa valeur était soustraite aux règles par
# motif, pour qu'un hôte légitime reste lisible. MESURÉ : ce bouclier désarmait
# la règle 2 sur la valeur de GIT_HOST — Y COMPRIS QUAND CETTE VALEUR ÉTAIT LE
# SECRET (« http://svc:4821/Xk9pQ@forge-inexistant-zz.invalid/x » sortait
# entier). Il est retiré : depuis la règle unique, une URL à « @ » est REFUSÉE
# en amont, donc jamais imprimée — et plus rien ne doit soustraire une valeur à
# l'expurgation. Le filet est de nouveau aussi glouton qu'il peut l'être.
# PASSE 7 : LE BOUCLIER AVAIT UN JUMEAU, ET C'ÉTAIT LA SIXIÈME FUITE. Le
# bouclier retiré, il restait un second endroit où le VERDICT désarmait
# l'expurgation : la GARDE de ce bloc, qui appelait _gc_host_userinfo. Pour un
# GIT_HOST de forme CHEMIN, elle sautait les règles 3 et 3bis — et les règles
# par motif ne rattrapaient pas (elles n'ont pas de « :// » à mordre, et la
# règle 1 s'arrête au premier « / » du jeton, fût-il celui du préfixe « ./ »).
# La garde appelle désormais _gc_host_ui_extract, qui n'a aucune exception.
_gc_redact(){
  local t="$1" sent segm mdp seg
  sent=$'\001'; segm=$'\003'
  # `if` et non `[ … ] && …` : c'est une LIB, un appelant sous `set -e` ne doit
  # pas être abattu par un test faux (même raison qu'au clients_etat plus bas).
  # _gc_host_ui_extract, JAMAIS _gc_host_userinfo : l'expurgation ne consulte
  # PLUS la notion de « chemin ». C'est le correctif de la passe 7 (cf. l'encadré
  # « DEUX QUESTIONS, DEUX FONCTIONS » plus haut) — remettre ici le verdict
  # rouvre la sixième fuite, mot pour mot.
  if _gc_host_ui_extract && [ -n "$_GC_HOST_UI" ]; then
    t="${t//"${_GC_HOST_UI}@"/$sent}"
    # RÈGLE 3bis — LES SEGMENTS DU MOT DE PASSE, MESURÉE ET NÉCESSAIRE.
    # Le canari « ssh://git:CANARIJ/SLASH@forge.bdf.fr:2222/scm » a fui SOUS
    # LE KNOB, 2× par run, alors que la règle 3 était bien posée : ssh coupe
    # l'autorité au premier « / » et rend « Could not resolve hostname
    # git:CANARIJ ». Le littéral entier n'apparaît donc JAMAIS dans ce que git
    # écrit — il en écrit un MORCEAU. Ce n'est pas une devinette de plus : on
    # ne cherche aucune frontière, on masque CHAQUE segment d'une valeur qu'on
    # CONNAÎT, ce qui ne peut qu'élargir le masquage (jamais le rater d'un
    # caractère). Seul le MOT DE PASSE (après le premier « : » du userinfo)
    # est découpé — le nom d'utilisateur, lui, est souvent « git » ou « x » et
    # le masquer partout rendrait la sortie de git illisible. Segments de
    # moins de 4 caractères ignorés, pour la même raison.
    case "$_GC_HOST_UI" in *:*) mdp="${_GC_HOST_UI#*:}" ;; *) mdp="" ;; esac
    if [ -n "$mdp" ]; then
      while IFS= read -r seg; do
        [ "${#seg}" -ge 4 ] || continue
        t="${t//"$seg"/$segm}"
      done < <(printf '%s' "$mdp" | tr '/:@ \t' '\n')
    fi
  fi
  t="${t//<identifiants masqués>@/$sent}"
  t=$(printf '%s' "$t" \
    | sed -E 's#(^|[[:space:]])[^[:space:]/]*@#\1<identifiants masqués>@#g' \
    | sed -E 's#://[^[:space:]]*@#://<identifiants masqués>@#g')
  t="${t//"$sent"/<identifiants masqués>@}"
  t="${t//"$segm"/<identifiants masqués>}"     # segment : pas de « @ », il est au MILIEU d'un jeton
  printf '%s' "$t"
}
# CE QUE CE FICHIER TIENT, ET CE QU'IL NE TIENT PAS (2026-09-08, passe 7).
# Ce paragraphe a menti QUATRE FOIS, toujours dans le sens qui rassure. Il est
# réécrit sur ce qui a été MESURÉ ce jour, et rien d'autre n'y est écrit. AUCUNE
# phrase absolue n'y figure sans l'énumération qui la démontre.
#
# REFUSÉ : tout GIT_HOST contenant un « @ », SAUF ceux qui commencent par « / »,
#   « ./ », « ../ » ou « ~ ». (La phrase d'avant écrivait « REFUSÉ — C'EST LA
#   GARANTIE : TOUT GIT_HOST contenant un @ », que l'exception démentait deux
#   lignes plus bas ; la clause est désormais dans la MÊME phrase.) Mesuré sur
#   les 30 formes de la § 25a (19 refusées) et les cas de la § 22, dont les
#   caractères des passes 1 à 4 et l'autorité qui ressemble à un hôte. Le refus
#   tombe avant que git ne soit invoqué une seule fois (shim de PATH, § 25b) et
#   ne cite ni le secret ni l'hôte (§ 22, § 25c).
# JAMAIS REFUSÉ, PAR CONSTRUCTION : un GIT_HOST qui COMMENCE par « / », « ./ »,
#   « ../ » ou « ~ » (les harnais clonent depuis /tmp). L'exception ne lit QUE
#   le premier caractère, elle n'a donc aucune frontière à deviner.
#   MAIS ELLE NE VAUT PLUS QUE POUR LE VERDICT (passe 7) : ces quatre formes
#   sont désormais EXPURGÉES comme les autres. MESURÉ, avant/après, sur les
#   quatre canaris de la § 22 (cas 19a-19d — « /u:… », « ./u:… », « ../u:… »,
#   « ~u:… » portant chacun un secret à tête et queue) :
#     AVANT — 3 LIGNES de stderr citent le secret par run (5 occurrences pour
#             les formes « / », « ./ », « ../ » ; 3 pour « ~ »), IDENTIQUE avec
#             et sans le knob, rc 0, sans refus ni avertissement ;
#     APRÈS — 0, des deux côtés, tête ET queue.
#   La § 22bis le prouve par MUTATION de la lib : recoupler l'expurgation au
#   verdict fait rougir les quatre canaris.
# TOLÉRÉ SOUS KNOB (GIT_HOST_USERINFO_TOLERE=1, et rien d'autre) : il ne reste
#   alors QUE l'expurgation, un FILET. Ce qu'elle attrape, mesuré : le littéral
#   de GIT_HOST (règle 3) et chaque segment d'au moins 4 caractères de son mot
#   de passe (règle 3bis, pour le transport qui TRONQUE — ssh coupe l'autorité
#   au premier « / »).
# CE QUE L'EXPURGATION N'ATTEINT PAS :
#   (a) TOUT CE QUE CETTE LIB N'IMPRIME PAS ELLE-MÊME. Elle n'expurge que ses
#       propres messages et la sortie du clone qu'elle capture ; git sur ses
#       autres canaux, un proxy dans SON journal, Jenkins dans le log de build
#       (il ne masque pas GIT_HOST : c'est une valeur d'environment{}, pas un
#       credential), et les AUTRES scripts du dépôt qui lisent GIT_HOST sans le
#       refuser ni l'expurger (cf. l'incohérence nommée en tête de fichier) sont
#       hors de sa portée, par construction. C'est le trou PRINCIPAL, il est
#       structurel, et c'est POUR LUI que le refus existe.
#   (b) UN SEGMENT DE MOINS DE 4 CARACTÈRES quand le transport tronque. MESURÉ :
#       'ssh://git:Zq7/LONGSEGMENT@forge.bdf.fr:2222/scm' laisse sortir « Zq7 »
#       2 fois
#       (seuil délibéré — masquer « dev », « api » ou « git » partout rendrait
#       le diagnostic illisible). Gardé en § 25f, des DEUX côtés : le segment
#       long réémis est masqué, le court sort.
#   (c) UN SECRET QUI NE VIENT PAS DE GIT_HOST (URL de proxy réémise par git,
#       URL de sous-module) : la règle 3 ne le CONNAÎT pas, il ne reste que les
#       règles par motif. CE QU'ELLES FONT, MESURÉ CAS PAR CAS — et non plus
#       résumé par la formule « elles s'arrêtent sur le « / » », qui était
#       fausse pour l'une des deux et illustrée par un seul cas favorable :
#         'http://u:SEC/RET@proxy-zz.invalid/x' → MASQUÉ (règle 2 : sa classe
#            est [^[:space:]]*, elle ne s'arrête PAS sur « / » ; il lui faut un
#            « :// »)
#         'ssh://u:SEC/RET@sub-zz.invalid/x'    → MASQUÉ (même raison)
#         'u:SECRET@proxy-zz.invalid:scm'       → MASQUÉ (règle 1, scp-like)
#         'u:SEC/RET@proxy-zz.invalid:scm'      → EN CLAIR (règle 1 : sa classe
#            est [^[:space:]/]*, elle s'arrête au PREMIER « / » du jeton — et ce
#            « / » n'est pas forcément dans le secret : sur la lib d'AVANT,
#            './u:SECRET123@forge' fuyait alors que le secret n'en contenait
#            aucun ; le « / » qui bloquait était celui du préfixe « ./ »)
#       Résumé exact : sans « :// », un secret contenant un « / » n'est pas
#       masqué par les règles par motif. C'est pourquoi la règle 3 (littérale,
#       qui CONNAÎT GIT_HOST) ne doit jamais dépendre d'un verdict de forme.
# SUR-EXPURGATION, l'autre côté de l'arbitrage, assumé et désormais plus large :
#   (1) sous knob, une URL dont le CHEMIN porte un « @ » est masquée jusqu'à ce
#       « @ » et son hôte devient illisible (§ 22, cas 20 et 23) — sans knob
#       elle est REFUSÉE, donc jamais imprimée ;
#   (2) NOUVEAU EN PASSE 7, ET C'EST LE PRIX DU CORRECTIF : un CHEMIN LOCAL qui
#       porte un « @ » est lui aussi masqué jusqu'à son DERNIER « @ », sans knob
#       ni refus. MESURÉ : « /tmp/gencho.XXXX/forge@local/depots/a.git » →
#       « <identifiants masqués>@local/depots/a.git » ; le diagnostic garde ce
#       qui SUIT le « @ » et perd le préfixe. Modeste, et préférable à un secret
#       en clair. Gardé en § 22 (cas 19) ;
#   (3) une adresse de courriel isolée dans la sortie de git est masquée aussi :
#       hors contexte, elle a la MÊME forme qu'un scp-like, et les distinguer
#       serait redevenir un devineur.
# CE QUI EST COUVERT, EXACTEMENT : les messages que cette lib émet elle-même,
# pour un secret qui vient de GIT_HOST — QUELLE QUE SOIT LA FORME de GIT_HOST,
# chemin compris —, rendu tel quel OU tronqué sur un séparateur d'URL avec des
# morceaux d'au moins 4 caractères. FILET.
# LA GARANTIE, C'EST LE REFUS — et le filet ne sert qu'à qui l'a désactivé, ou
# à qui sert un dépôt depuis un chemin local (que le refus, lui, laisse passer).
# _gc_host / _gc_base — LES défauts, en UN seul endroit (2026-09-07). Chaque
# message qui les recopiait pouvait mentir : l'avertissement d'un dépôt d'équipe
# écrivait « sur main » en dur alors que le clone demandait ${GIT_BASE:-main},
# et servait donc un diagnostic FAUX à un client dont la base est master.
_gc_host(){ printf '%s' "${GIT_HOST:-http://gitea:3000}"; }
_gc_base(){ printf '%s' "${GIT_BASE:-main}"; }
# _gc_emit_marker <n> — LE SEUL point d'émission du marqueur (2026-09-07 bis).
# L'en-tête promettait « émis sur TOUS les chemins d'échec » alors que trois
# `echo` recopiés le portaient sur TROIS chemins ; les quatre autres (MKTEMP,
# GIT_UNREACHABLE, PROVIDERS_MISSING, PROVIDERS_PARSE) sortaient muets. Une
# promesse tenue par recopie n'est pas tenue : elle l'est jusqu'au prochain
# chemin d'échec ajouté. Un helper, appelé sur chacune des sorties, et une
# épreuve qui balaie les NEUF chemins un par un (§ 17).
_gc_emit_marker(){ echo "CHOICES_SKIPPED_REPOS=${1:-0}" >&2; }
# _gc_source_desc — d'OÙ vient le dépôt plateforme de ce run, expurgé.
# Remplace l'expansion `${GC_PLATFORM_DIR:+…}${GC_PLATFORM_DIR:-…}` des refus
# GIT_UNREACHABLE, qui collait le libellé au chemin (« répertoire
# fourni/home/jenkins/… ») et relayait ce chemin SANS _gc_redact — écart à la
# règle du dépôt, alors que le refus voisin, lui, le masquait.
_gc_source_desc(){
  if [ -n "${GC_PLATFORM_DIR:-}" ]; then
    printf 'répertoire fourni %s' "$(_gc_redact "$GC_PLATFORM_DIR")"
  else
    printf 'clone depuis %s' "$(_gc_redact "$(_gc_host)")"
  fi
}
# _gc_platform_ref — COMMENT nommer le dépôt plateforme dans un refus, sans
# rien affirmer de faux (2026-09-07). Les refus écrivaient « dépôt plateforme
# ci/stoa-labs@main » DANS TOUS LES CAS. Avec GC_PLATFORM_DIR, aucun dépôt et
# aucune branche n'ont pourtant été consultés : c'est un RÉPERTOIRE qui a été
# lu — et chez le client concerné « ci/stoa-labs » n'existe même pas. Mesuré :
#   GC_PLATFORM_DIR=<ws> GIT_BASE=master … ⇒ « PROVIDERS_MISSING : … absent du
#   dépôt plateforme ci/stoa-labs@master (répertoire fourni …) »
# Sur le chemin de CLONE, au contraire, le nom du dépôt est LA question du
# client (« quel dépôt est cloné ? ») : il est nommé, avec sa branche.
_gc_platform_ref(){
  if [ -n "${GC_PLATFORM_DIR:-}" ]; then
    printf 'dépôt plateforme (%s)' "$(_gc_source_desc)"
  else
    printf 'dépôt plateforme %s@%s (%s)' "${GIT_REPO:-ci/stoa-labs}" "$(_gc_base)" "$(_gc_source_desc)"
  fi
}
_gc_clone(){
  local repo="$1" dest="$2"
  # _GC_CLONE_ERR est REMIS À ZÉRO ici (2026-09-07) : c'est une globale, et son
  # premier consommateur par dépôt est l'avertissement du corps de boucle. Sans
  # cette remise à zéro, la cause du dépôt A pouvait être servie pour le dépôt
  # B ; et sur le chemin SECRET_FORGE_REQUIS ci-dessous elle n'était pas posée
  # DU TOUT, si bien que l'avertissement disait « aucune sortie de git » alors
  # que la vraie cause était un secret manquant (mesuré).
  _GC_CLONE_ERR=""
  # LE SECRET DE LA FORGE, quel qu'il soit (déploiement client 2026-09-04).
  # Un gestionnaire d'identité ne rend pas toujours un JETON : Jenkins rend
  # souvent un COUPLE (usernamePassword). Pour git, les deux valent : le clone
  # ne fait qu'un Basic, où un mot de passe occupe la place du jeton. Seul le
  # NOM de la variable prétendait le contraire, et le refus qui suivait réclamait
  # un jeton que le client n'aura jamais.
  #   FORGE_SECRET  le secret, jeton OU mot de passe (nom neutre, à préférer)
  #   GITEA_TOKEN   alias historique, toujours honoré
  #   FORGE_USER / GIT_USER  l'utilisateur du couple (défaut « x », que seul Gitea accepte)
  local token="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
  # 2026-09-07 : le message nommait DEUX FOIS la même variable (« FORGE_SECRET
  # ou son alias FORGE_SECRET ») et jamais l'alias réellement lu, GITEA_TOKEN —
  # instruction circulaire pour l'opérateur client. Aligné sur la formulation
  # des scripts frères (provision-request.sh:170, team-apply.sh:75).
  [ -n "$token" ] || { _GC_CLONE_ERR="SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN (aucun clone tenté)"
    echo "SECRET_FORGE_REQUIS : aucun secret pour la forge — ni FORGE_SECRET (jeton, ou mot de passe d'un couple) ni son alias GITEA_TOKEN ; avec un couple, poser aussi FORGE_USER" >&2; return 1; }
  local host; host="$(_gc_host)"
  # GIT_USER : l'utilisateur du Basic. Gitea accepte n'importe lequel avec un
  # PAT, d'où le « x » historique — GitLab et Bitbucket, NON (401). Knob, défaut
  # inchangé. GIT_BASE : la branche de base, knob d'ADR-075 honoré partout
  # ailleurs (provision-request.sh:393) et jusqu'ici IGNORÉ ici — un client dont
  # la branche est `master`/`develop` voyait donc échouer CE clone, et lui seul.
  local user="${FORGE_USER:-${GIT_USER:-x}}" base; base="$(_gc_base)"
  local auth_b64 err rc
  auth_b64=$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')
  err=$(mktemp) || { _GC_CLONE_ERR="mktemp indisponible"; return 1; }
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q --depth 1 -b "$base" "${host}/${repo}.git" "$dest" 2>"$err"
  rc=$?
  # expurgation : un identifiant glissé dans GIT_HOST (http://user:jeton@hote)
  # ressortirait par stderr — on ne relaie jamais la partie userinfo d'une URL.
  # L'EXPURGATION PASSE AVANT L'APLATISSEMENT (2026-09-07 quater). L'ordre
  # d'avant — `_gc_redact "$(tr '\n' ' ' < "$err")"` — remplaçait les sauts de
  # ligne par des espaces AVANT la règle 3 : le littéral d'un GIT_HOST à saut de
  # ligne (« u:CAN␤ARI@ ») ne matchait alors plus rien, puisque le texte portait
  # désormais « u:CAN ARI@ ». On expurge la sortie TELLE QUELLE, puis on aplatit.
  _GC_CLONE_ERR=$(_gc_redact "$(cat "$err")" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  rm -f "$err"
  return "$rc"
}
# _gc_fetch_main <dest> — le dépôt PLATEFORME, par le réseau… ou pas.
# GC_PLATFORM_DIR : racine d'un dépôt plateforme DÉJÀ présent (opt-in). Un job
# « pipeline from SCM » sur ce dépôt l'a déjà dans le workspace de l'agent
# (lightweight=false) : le re-cloner exige d'un client un hôte joignable, un
# jeton, une branche de base et une traversée de proxy pour lire un fichier
# qu'il a sous la main — et c'est le PREMIER geste réseau de la chaîne, donc le
# premier à tomber (déploiement client 2026-09-03 : EQUIPES_INDISPONIBLES sans
# cause). L'appelant qui pose ce knob AFFIRME que ce répertoire est le dépôt
# plateforme à la bonne révision ; en Jenkins c'est la définition SCM du job qui
# l'assure. Les listes restent de l'ERGONOMIE (l'autorité est dans les gardes).
# FAIL-CLOSED : un knob qui ne porte pas le dépôt ne retombe JAMAIS sur un
# clone — un repli masquerait la méprise de configuration.
_gc_fetch_main(){
  local dest="$1"
  if [ -n "${GC_PLATFORM_DIR:-}" ]; then
    if [ ! -d "${GC_PLATFORM_DIR}/${SUB_PFX}ansible" ]; then
      _GC_CLONE_ERR="GC_PLATFORM_DIR=$(_gc_redact "$GC_PLATFORM_DIR") ne porte pas ${SUB_PFX}ansible — répertoire fourni par l'appelant, aucun repli sur un clone"
      return 1
    fi
    rm -df "$dest" 2>/dev/null
    ln -s "$GC_PLATFORM_DIR" "$dest" 2>/dev/null || {
      _GC_CLONE_ERR="lien vers GC_PLATFORM_DIR impossible ($dest)"; return 1; }
    return 0
  fi
  _gc_clone "${GIT_REPO:-ci/stoa-labs}" "$dest"
}
_gc_fetch_team_repo(){ _gc_clone "$1" "$2"; }                          # dépôt d'équipe

# _gc_collect_publish_yml <dir> <outfile> — ajoute "nom@version" (une ligne
# par match) à <outfile> pour chaque .../apis/*.publish.yml sous <dir>.
# Un fichier ABSENT (rien sous <dir>) n'est pas une erreur. Un fichier
# PRÉSENT mais illisible/malformé (apim_api.name ou .version manquant, YAML
# cassé) FAIT ÉCHOUER l'appel (return 1) — corruption réelle, jamais un skip
# silencieux qui laisserait une API manquante sans que personne ne le sache.
_gc_collect_publish_yml(){
  local dir="$1" outfile="$2" f perr
  [ -d "$dir" ] || return 0
  # `find -L` (2026-09-07) : en -P (le défaut) find NE TRAVERSE PAS un lien
  # symbolique en dernier composant, alors que le `[ -d "$dir" ]` ci-dessus, lui,
  # LE SUIT — et c'est ce test qui alimente l'état « présent » du refus
  # APIS_EMPTY. Un clients/ symbolique (workspace d'agent, dépôt rangé
  # autrement) rendait donc « répertoire présent … → 0 fichier » : la présence
  # affirmée d'un répertoire dont RIEN n'avait été lu (mesuré). Les deux gestes
  # suivent les liens, ou aucun ne doit les suivre.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    perr=$(mktemp)
    if ! python3 - "$f" <<'PY' >>"$outfile" 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
api = d.get("apim_api") or {}
name, ver = api.get("name"), api.get("version")
if name and ver:
    print(f"{name}@{ver}")
else:
    sys.exit("apim_api.name/version manquant")
PY
    then
      echo "PUBLISH_YML_PARSE : ${f} illisible — $(cat "$perr")" >&2
      rm -f "$perr"
      return 1
    fi
    rm -f "$perr"
  done < <(find -L "$dir" -type f -path '*/apis/*.publish.yml' 2>/dev/null | sort)
}

# generate_choices_teams_raw <env> — une équipe par ligne, NON échappée, dans
# l'ordre de providers.<env>.yml. A0 (2026-09-02) : consommée par
# scripts/app-request-choices.sh, qui pose le formulaire app-request depuis son
# Jenkinsfile — il lui faut des VALEURS, pas des fragments XML. Même contrat
# fail-closed que le wrapper XML ci-dessous (qui n'est plus qu'un habillage).
generate_choices_teams_raw(){
  # ENV_REQUIS plutôt qu'un « ${1:?} » de bash (2026-09-07 ter). Mesuré, l'ancien :
  # rc=127, message préfixé « fichier: ligne N: 1: … » (donc pas un refus en TÊTE
  # de ligne), et — pire — le shell APPELANT est ABATTU : `${1:?}` fait sortir un
  # shell non interactif, un `|| return 1` de l'appelant n'est jamais atteint.
  # Règle du dépôt (cf. « champ obligatoire = message clair ») : jamais un
  # ${VAR:?}, un refus nommé. Ici SANS marqueur — c'est l'entrée TEAMS, et le
  # contre-témoin de la § 17 en dépend.
  local envn="${1:-}"
  if [ -z "$envn" ]; then
    echo "ENV_REQUIS : generate_choices_teams_raw attend l'environnement en 1er argument (ex. dev) — aucun accès à la forge tenté" >&2
    return 1
  fi
  # I1 — LA PORTE, avant le premier mktemp, avant le premier clone, avant tout
  # message qui citerait l'hôte (cf. l'encadré « UN GIT_HOST QUI PORTE DES
  # IDENTIFIANTS » plus haut). Sans marqueur : c'est l'entrée TEAMS.
  _gc_gate_host_userinfo || return 1
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2; return 1; }

  if ! _gc_fetch_main "$work"; then
    echo "GIT_UNREACHABLE : accès au $(_gc_platform_ref) en échec — ${_GC_CLONE_ERR:-aucune sortie de git}" >&2
    rm -rf "$work"; return 1
  fi
  local prov="$work/${SUB_PFX}ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ${SUB_PFX}ansible/providers.${envn}.yml absent du $(_gc_platform_ref) — chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR}'" >&2
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" out
  if ! out=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    t = p.get("team")
    if t:
        print(t)
PY
  ); then
    echo "PROVIDERS_PARSE : providers.${envn}.yml illisible — $(cat "$perr" 2>/dev/null)" >&2
    rm -rf "$work"; return 1
  fi
  rm -rf "$work"

  if [ -z "$out" ]; then
    echo "PROVIDERS_EMPTY : aucune équipe déclarée dans providers.${envn}.yml" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# generate_choices_teams <env> — cf. en-tête : fragments <string>…</string>
# (habillage XML de la variante brute, sortie IDENTIQUE à celle d'avant A0).
generate_choices_teams(){
  # « ${1:-} » et non « $1 » (2026-09-07 quater) : sous `set -u` — que les
  # QUATRE appelants réels utilisent — un « $1 » nu sur une fonction appelée
  # sans argument fait sortir le shell APPELANT sur « $1: unbound variable ».
  # Même défaut que le ${VAR:?} fermé une couche plus bas, une couche au-dessus :
  # la garde de la variante _raw rendait déjà un refus NOMMÉ, mais personne ne
  # l'atteignait. On laisse la garde d'en dessous parler — un seul message.
  local out
  out=$(generate_choices_teams_raw "${1:-}") || return 1
  while IFS= read -r t; do
    [ -n "$t" ] && printf '<string>%s</string>\n' "$(_gc_escape "$t")"
  done <<<"$out"
}

# generate_choices_apis_raw <env> — un « nom@version » par ligne, NON échappé,
# trié (sort -u). Même rôle que generate_choices_teams_raw ; le marqueur
# CHOICES_SKIPPED_REPOS=<n> (stderr) est émis ICI, donc aussi par le wrapper.
generate_choices_apis_raw(){
  # Les compteurs sont déclarés EN TÊTE (2026-09-07 bis) : le marqueur sort sur
  # CHACUNE des sorties de cette fonction, y compris les CINQ qui précèdent la
  # lecture de providers — il ne peut le faire que si `skipped` existe déjà.
  # Sur ces cinq chemins il vaut 0, et c'est un FAIT : rien n'a été sauté,
  # parce que rien n'a été tenté. C'est ce que l'appelant a besoin de savoir.
  local skipped=0 declares=0 clones=0
  # HUITIÈME SORTIE, ET ELLE ÉTAIT MUETTE (2026-09-07 ter). L'en-tête promettait
  # le marqueur « sur TOUS les chemins d'échec » et la § 17 en balayait SEPT ; la
  # garde d'argument `${1:?env requis}` en était une HUITIÈME, jamais comptée.
  # Et pas seulement muette — mesuré : rc=127, message préfixé « fichier: ligne
  # N: » (donc pas un refus en tête de ligne), et le shell APPELANT ABATTU
  # (`${1:?}` fait sortir un shell non interactif : le `|| return 1` de
  # l'appelant n'est jamais atteint). Refus nommé, en tête, AVEC le marqueur,
  # avant tout contact avec la forge — comme les sept autres.
  local envn="${1:-}"
  if [ -z "$envn" ]; then
    echo "ENV_REQUIS : generate_choices_apis_raw attend l'environnement en 1er argument (ex. dev) — aucun accès à la forge tenté" >&2
    _gc_emit_marker "$skipped"
    return 1
  fi
  # NEUVIÈME SORTIE (2026-09-07 quater) — I1 : la porte GIT_HOST. Elle est une
  # sortie de plus de cette fonction, et l'en-tête promet le marqueur sur
  # TOUTES : elle l'émet, comme les huit autres, avec skipped=0 (rien n'a été
  # sauté, parce que rien n'a été tenté). Une promesse absolue se démontre en
  # énumérant, et une énumération incomplète la rend fausse sans que rien ne
  # rougisse — c'est exactement ce qui est arrivé à la septième, puis à la
  # huitième. La § 17 en balaie NEUF.
  if ! _gc_gate_host_userinfo; then
    _gc_emit_marker "$skipped"
    return 1
  fi
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2
    _gc_emit_marker "$skipped"; return 1; }

  if ! _gc_fetch_main "$work/platform"; then
    echo "GIT_UNREACHABLE : accès au $(_gc_platform_ref) en échec — ${_GC_CLONE_ERR:-aucune sortie de git}" >&2
    _gc_emit_marker "$skipped"
    rm -rf "$work"; return 1
  fi
  local root="$work/platform/${SUB_PFX%/}"
  local prov="$root/ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ${SUB_PFX}ansible/providers.${envn}.yml absent du $(_gc_platform_ref) — chemin RELATIF à la racine du dépôt, préfixe GIT_SUBDIR='${GIT_SUBDIR}'" >&2
    _gc_emit_marker "$skipped"
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" repos
  if ! repos=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    r = p.get("repo")
    if r:
        print(r)
PY
  ); then
    echo "PROVIDERS_PARSE : providers.${envn}.yml illisible — $(cat "$perr" 2>/dev/null)" >&2
    _gc_emit_marker "$skipped"
    rm -rf "$work"; return 1
  fi

  local names="$work/.names"; : > "$names"

  # clients/ du dépôt plateforme lui-même (squelettes ADR-076 déjà onboardés,
  # ex. clients/_example/apis/accounts-read.publish.yml).
  # 2026-09-07 : l'ÉTAT du répertoire est relevé ICI, tant que $work existe —
  # _gc_collect_publish_yml rend 0 EN
  # SILENCE sur un répertoire absent (garde ligne « [ -d "$dir" ] || return 0 »),
  # si bien qu'un clients/ jamais atteint (mauvais GIT_SUBDIR/GC_PLATFORM_DIR)
  # et un clients/ réellement vide rendaient le même refus muet.
  # `if` et non `[ … ] && …` : un appelant qui sourcerait la lib sous `set -e`
  # (aucun ne le fait aujourd'hui, mais c'est une LIB) serait abattu par le test
  # faux — un répertoire absent est justement le cas qu'on veut NOMMER.
  local clients_dir="$root/clients" clients_etat="ABSENT"
  if [ -d "$clients_dir" ]; then clients_etat="présent"; fi
  if ! _gc_collect_publish_yml "$clients_dir" "$names"; then
    _gc_emit_marker "$skipped"
    rm -rf "$work"; return 1
  fi
  # PAS DE COMPTE DE FICHIERS ICI (2026-09-07). Il en existait un, servi par
  # APIS_EMPTY (« motif … → N fichier(s) ») : une MESURE MORTE. APIS_EMPTY n'est
  # atteint que si la liste finale est VIDE, et un publish.yml retenu la
  # remplirait ; un publish.yml présent mais illisible sort, lui, en
  # PUBLISH_YML_PARSE. N valait donc 0 par construction, sur tout chemin
  # d'exécution — mutation jouée : forcer N=42 laissait la suite verte, et le
  # refus aurait servi « → 42 fichier(s) » sans que rien ne rougisse. Un refus
  # de ce dépôt ne porte pas un nombre que personne ne peut démentir.

  # dépôts d'équipe déclarés — CHACUN son propre clone (ce sont des dépôts
  # SÉPARÉS de la plateforme, cf. ADR-076, pas des sous-dossiers de
  # ci/stoa-labs). Un dépôt introuvable est attendu tant que T5/T6 n'ont pas
  # livré la chaîne producteur : averti, ignoré POUR CETTE LISTE, pas fatal —
  # mais COMPTÉ (skipped) : le nombre est le signal réutilisable par
  # l'appelant, cf. marqueur CHOICES_SKIPPED_REPOS — émis sur CHACUN des chemins
  # de sortie de cette fonction, jamais à une position promise.
  # 2026-09-07 : l'URL et la branche sont composées ICI comme _gc_clone les
  # compose (mêmes helpers, pas une recopie), pour que l'avertissement dise
  # EXACTEMENT ce que git a tenté — c'est la question du client : « quel dépôt
  # est cloné ». L'hôte passe par _gc_redact : un opérateur qui met ses
  # identifiants dans GIT_HOST ne les verra pas ressortir par ce message.
  local rrepo tw base_b host_red url_red
  base_b="$(_gc_base)"; host_red="$(_gc_redact "$(_gc_host)")"
  while IFS= read -r rrepo; do
    [ -n "$rrepo" ] || continue
    declares=$((declares + 1))
    tw="$work/team-$(printf '%s' "$rrepo" | tr './' '__')"
    if _gc_fetch_team_repo "$rrepo" "$tw"; then
      clones=$((clones + 1))
      if ! _gc_collect_publish_yml "$tw" "$names"; then
        # Des dépôts ont pu être sautés AVANT que cette corruption ne soit
        # trouvée — le compte doit sortir, comme sur le chemin d'APIS_EMPTY.
        _gc_emit_marker "$skipped"
        rm -rf "$work"; return 1
      fi
    else
      skipped=$((skipped + 1))
      url_red="${host_red}/${rrepo}.git"
      # _GC_CLONE_ERR est DÉJÀ expurgé par _gc_clone — il était calculé puis
      # JETÉ ici : 401, 404, branche absente, proxy et TLS rendaient le même
      # message, et le client ne pouvait pas les distinguer (incident du jour).
      echo "  (avertissement) dépôt d'équipe ${rrepo} illisible sur ${base_b} (${url_red}) — ignoré pour cette liste — ${_GC_CLONE_ERR:-aucune sortie de git}" >&2
    fi
  done <<<"$repos"

  local result
  result=$(sort -u "$names" 2>/dev/null)
  rm -rf "$work"

  # La DERNIÈRE émission : elle couvre à la fois le SUCCÈS et le
  # refus APIS_EMPTY (y compris skipped=0) — cf. en-tête "SIGNAL DE TOLÉRANCE".
  # Émise AVANT les fragments XML pour ne jamais dépendre de l'ordre d'un flush
  # partiel côté appelant ; sur stderr, SEULE sur sa ligne (grep ancré de
  # test-a0-wiring.sh, et grep -oE de team-apply.sh:407 / team-publish.sh:470),
  # jamais mêlée au fragment stdout.
  # 2026-09-07 : remontée AVANT le test de vacuité — elle vivait après le
  # `return 1` d'APIS_EMPTY, donc disparaissait exactement dans le cas où elle
  # compte le plus (« combien de dépôts d'équipe ont été sautés ? » sur le rouge).
  _gc_emit_marker "$skipped"

  if [ -z "$result" ]; then
    # 2026-09-07 : le refus nomme CE QU'IL A REGARDÉ. Sans cela le client ne
    # pouvait ni poser un fichier au bon endroit, ni savoir quel dépôt réparer
    # — toutes ces valeurs étaient vivantes à cet instant et aucune n'était
    # imprimée, sur aucun chemin d'exécution. La SOURCE passe par
    # _gc_platform_ref : sur le chemin de CLONE (GC_PLATFORM_DIR non posé —
    # c'est le mode de setup-team-onboard-jobs.sh, donc de la re-pose
    # déclenchée par team-apply.sh et team-publish.sh) le refus nomme enfin
    # ${GIT_REPO}@branche, comme le font déjà ses deux refus frères ; la
    # question littérale du client était « quel dépôt est cloné ».
    # Le VOLET « dépôts d'équipe » ne cite la forge et la branche que si un
    # dépôt a été DÉCLARÉ : sans déclaration, aucune branche et aucun hôte n'ont
    # été mis en jeu, et « 0 illisible(s) sur main (http://…) » nommerait un
    # hôte que ce run n'a jamais approché.
    local repos_desc
    if [ "$declares" -eq 0 ]; then
      repos_desc="aucun dépôt d'équipe déclaré"
    else
      repos_desc="${declares} dépôt(s) d'équipe déclaré(s), ${clones} cloné(s), ${skipped} illisible(s) sur ${base_b} (${host_red})"
    fi
    # LE REMÈDE NE RENVOIE À DES AVERTISSEMENTS QUE S'IL Y EN A EU (2026-09-07
    # bis). « ou réparer les dépôts d'équipe avertis ci-dessus » était émis
    # INCONDITIONNELLEMENT — donc aussi quand aucun dépôt n'était déclaré, et
    # quand tous avaient été clonés : l'opérateur était renvoyé vers des
    # avertissements qui n'existaient pas. C'est exactement la classe de défaut
    # que ce fichier prétend abolir, réintroduite par le correctif qui la
    # dénonçait. La condition est `skipped` — le compte des dépôts RÉELLEMENT
    # avertis (un `declares > 0` ne suffirait pas : tous clonés ⇒ zéro
    # avertissement), et le remède le CITE, pour que « ci-dessus » soit vérifiable.
    local remede="poser ${SUB_PFX}clients/<projet>/apis/<nom>.publish.yml dans le dépôt plateforme"
    if [ "$skipped" -gt 0 ]; then
      remede="${remede}, ou réparer les ${skipped} dépôt(s) d'équipe avertis ci-dessus"
    fi
    echo "APIS_EMPTY : aucune API publiée trouvée — source : $(_gc_platform_ref). Balayé ${SUB_PFX}clients — répertoire ${clients_etat}, motif '*/apis/*.publish.yml' → aucun fichier retenu ; ${SUB_PFX}ansible/providers.${envn}.yml → ${repos_desc}. REMÈDE : ${remede}" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# generate_choices_apis <env> — cf. en-tête : fragments <string>…</string>
# (habillage XML de la variante brute, sortie IDENTIQUE à celle d'avant A0).
generate_choices_apis(){
  # « ${1:-} » et non « $1 » : cf. generate_choices_teams ci-dessus. Sous
  # `set -u`, un « $1 » nu abattait le shell appelant AVANT que la garde
  # ENV_REQUIS de la variante _raw — et son marqueur — n'aient pu sortir.
  local out
  out=$(generate_choices_apis_raw "${1:-}") || return 1
  while IFS= read -r n; do
    [ -n "$n" ] && printf '<string>%s</string>\n' "$(_gc_escape "$n")"
  done <<<"$out"
}
