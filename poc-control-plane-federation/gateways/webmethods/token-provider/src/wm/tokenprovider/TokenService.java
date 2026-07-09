package wm.tokenprovider;

import com.wm.app.b2b.server.ServiceException;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/**
 * Acquisition d'un jeton aupres d'un provider, entierement pilotee par le
 * profil : URL templatee, body template (form ou JSON), credentials venant de
 * Vault, extraction du jeton et de sa duree de vie configurables.
 *
 * Les valeurs secretes ne sont jamais loggees ni incluses dans les messages
 * d'erreur (les templates en erreur sont rapportes en version redactee) ;
 * le body de la reponse du provider n'est jamais propage. Les valeurs de
 * header rendues sont refusees si elles contiennent CR/LF (anti header
 * smuggling depuis un secret ou un provider compromis).
 */
public final class TokenService {

    public static final class Result {
        public final String token;
        public final String tokenType;
        public final long ttlSeconds;
        Result(String token, String tokenType, long ttlSeconds) {
            this.token = token; this.tokenType = tokenType; this.ttlSeconds = ttlSeconds;
        }
    }

    private TokenService() {}

    public static Result fetch(String profileName) throws ServiceException {
        ProviderConfig.Profile p = ProviderConfig.profile(profileName);

        Map<String, String> vars = new HashMap<>(p.params);
        if (p.vaultPath != null && !p.secretMap.isEmpty()) {
            Map<String, String> secrets = VaultClient.getSecrets(p.vaultPath);
            for (Map.Entry<String, String> e : p.secretMap.entrySet()) {
                String value = secrets.get(e.getValue());
                if (value == null) {
                    throw new ServiceException("TokenProvider[" + profileName + "]: champ '" + e.getValue()
                            + "' absent du secret Vault '" + p.vaultPath + "'");
                }
                vars.put(e.getKey(), value);
            }
        }
        Set<String> secretKeys = p.secretMap.keySet();

        String url = render(profileName, "urlTemplate", p.urlTemplate, vars, TemplateEngine.Mode.URL, secretKeys);
        String body = p.bodyTemplate == null ? null
                : render(profileName, "bodyTemplate", p.bodyTemplate, vars,
                        TemplateEngine.modeForContentType(p.contentType), secretKeys);

        Map<String, String> headers = new HashMap<>();
        for (Map.Entry<String, String> e : p.requestHeaders.entrySet()) {
            String value = render(profileName, "header '" + e.getKey() + "'", e.getValue(), vars,
                    TemplateEngine.Mode.RAW, secretKeys);
            headers.put(e.getKey(), assertHeaderSafe(profileName, e.getKey(), value));
        }
        if (body != null && !containsKeyIgnoreCase(headers, "Content-Type")) {
            headers.put("Content-Type", p.contentType);
        }

        String basicUser = null;
        String basicPass = null;
        if (p.authUserVar != null) {
            basicUser = vars.get(p.authUserVar);
            if (basicUser == null) {
                throw new ServiceException("TokenProvider[" + profileName + "]: authUserVar '" + p.authUserVar
                        + "' ne correspond a aucun param ni secret");
            }
        }
        if (p.authPassVar != null) {
            basicPass = vars.get(p.authPassVar);
            if (basicPass == null) {
                throw new ServiceException("TokenProvider[" + profileName + "]: authPassVar '" + p.authPassVar
                        + "' ne correspond a aucun param ni secret");
            }
        }

        byte[] bodyBytes = null;
        if (body != null) {
            try {
                bodyBytes = body.getBytes("UTF-8");
            } catch (java.io.UnsupportedEncodingException e) {
                throw new IllegalStateException(e);
            }
        }

        Http.Result res = Http.request(url, p.method, headers, bodyBytes, basicUser, basicPass, p.timeoutMillis);
        if (res.status < 200 || res.status >= 300) {
            throw new ServiceException("TokenProvider[" + profileName + "]: le endpoint de jeton a repondu HTTP "
                    + res.status + " (" + Http.safeUrl(url) + ")");
        }

        com.wm.data.IData json = Json.parse(res.body);
        String token = Json.pathAsString(json, p.tokenPath);
        if (token == null || token.isEmpty()) {
            throw new ServiceException("TokenProvider[" + profileName + "]: chemin '" + p.tokenPath
                    + "' absent de la reponse du provider");
        }

        long ttl;
        if (p.fixedTtlSeconds != null) {
            ttl = p.fixedTtlSeconds;
        } else {
            String expiresIn = Json.pathAsString(json, p.expiresInPath);
            if (expiresIn == null) {
                throw new ServiceException("TokenProvider[" + profileName + "]: chemin '" + p.expiresInPath
                        + "' absent de la reponse du provider (ou utiliser fixedTtlSeconds)");
            }
            try {
                ttl = (long) Double.parseDouble(expiresIn);
            } catch (NumberFormatException e) {
                throw new ServiceException("TokenProvider[" + profileName + "]: valeur non numerique au chemin '"
                        + p.expiresInPath + "'");
            }
        }
        return new Result(token, p.tokenType, ttl);
    }

    // ------------------------------------------------------------------

    private static String render(String profileName, String what, String template, Map<String, String> vars,
                                 TemplateEngine.Mode mode, Set<String> secretKeys) throws ServiceException {
        try {
            return TemplateEngine.render(template, vars, mode);
        } catch (IllegalArgumentException e) {
            throw new ServiceException("TokenProvider[" + profileName + "]: " + e.getMessage()
                    + " — " + what + ": " + TemplateEngine.redact(template, secretKeys));
        }
    }

    static String assertHeaderSafe(String profileName, String headerName, String value) throws ServiceException {
        if (value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0) {
            throw new ServiceException("TokenProvider[" + profileName + "]: caracteres de controle dans le header '"
                    + headerName + "' — valeur refusee");
        }
        return value;
    }

    private static boolean containsKeyIgnoreCase(Map<String, String> map, String key) {
        for (String k : map.keySet()) {
            if (k.equalsIgnoreCase(key)) return true;
        }
        return false;
    }
}
