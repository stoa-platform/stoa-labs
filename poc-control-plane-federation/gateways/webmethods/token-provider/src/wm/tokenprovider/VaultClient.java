package wm.tokenprovider;

import com.wm.app.b2b.server.Service;
import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataFactory;
import com.wm.data.IDataUtil;
import com.wm.lang.ns.NSName;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Client HashiCorp Vault minimal : login AppRole + lecture KV v2 (ou v1).
 *
 * Secret-zero : le secret_id AppRole est lu dans l'outbound password store
 * de l'IS (chiffre par passman) — jamais dans un fichier ni un alias gateway.
 * pub.security.outboundPasswords:getPassword renvoie un WmSecureString
 * (sortie 'value'), converti via pub.security.util:convertSecureString.
 *
 * Le client_token Vault est cache jusqu'a 80% de sa lease (lease publiee
 * atomiquement via une reference unique) ; les secrets lus sont caches
 * cacheSecretsSeconds (defaut 300 s) pour ne pas marteler Vault a chaque
 * renouvellement de jeton backend.
 *
 * En 11.1+/12.1, remplacer cette classe par les built-ins pub.vault:* —
 * le reste du package ne change pas.
 */
public final class VaultClient {

    private static final class Lease {
        final String token;
        final long expiresAt;
        Lease(String token, long expiresAt) { this.token = token; this.expiresAt = expiresAt; }
    }

    private static volatile Lease lease;

    private static final class CachedSecrets {
        final Map<String, String> values;
        final long expiresAt;
        CachedSecrets(Map<String, String> values, long expiresAt) { this.values = values; this.expiresAt = expiresAt; }
    }

    private static final ConcurrentHashMap<String, CachedSecrets> secretCache = new ConcurrentHashMap<>();

    private VaultClient() {}

    /** Lit un secret KV et retourne ses champs (cle -> valeur). */
    public static Map<String, String> getSecrets(String path) throws ServiceException {
        if (path == null || path.isEmpty()) {
            throw new ServiceException("TokenProvider: vaultPath manquant dans le profil");
        }
        CachedSecrets cached = secretCache.get(path);
        long now = System.currentTimeMillis();
        if (cached != null && now < cached.expiresAt) return cached.values;

        ProviderConfig.Vault cfg = ProviderConfig.vault();
        String url = (cfg.kvVersion == 2)
                ? cfg.addr + "/v1/" + cfg.kvMount + "/data/" + path
                : cfg.addr + "/v1/" + cfg.kvMount + "/" + path;

        Map<String, String> headers = new HashMap<>();
        headers.put("X-Vault-Token", token(cfg));

        Http.Result res = Http.request(url, "get", headers, null, null, null, cfg.timeoutMillis);
        if (res.status == 403) {
            invalidate();
            headers.put("X-Vault-Token", token(cfg));
            res = Http.request(url, "get", headers, null, null, null, cfg.timeoutMillis);
        }
        if (res.status < 200 || res.status >= 300) {
            throw new ServiceException("TokenProvider: Vault a repondu HTTP " + res.status
                    + " pour le secret '" + path + "'");
        }

        IData doc = Json.parse(res.body);
        IData data = (IData) ((cfg.kvVersion == 2) ? Json.path(doc, "data.data") : Json.path(doc, "data"));
        if (data == null) {
            throw new ServiceException("TokenProvider: secret Vault '" + path + "' vide ou au mauvais format (kvVersion=" + cfg.kvVersion + ")");
        }
        Map<String, String> values = new HashMap<>();
        IDataCursor c = data.getCursor();
        while (c.next()) {
            Object v = c.getValue();
            if (v != null && !(v instanceof IData)) values.put(c.getKey(), String.valueOf(v));
        }
        c.destroy();

        secretCache.put(path, new CachedSecrets(values, now + cfg.cacheSecretsSeconds * 1000L));
        return values;
    }

    /** Eviction ciblee, utilisee quand le backend repond 401 (credentials probablement tournes). */
    public static void invalidateSecret(String path) {
        if (path != null) secretCache.remove(path);
    }

    public static void invalidate() {
        lease = null;
        secretCache.clear();
    }

    // ------------------------------------------------------------------

    private static String token(ProviderConfig.Vault cfg) throws ServiceException {
        Lease l = lease;
        if (l != null && System.currentTimeMillis() < l.expiresAt) return l.token;
        synchronized (VaultClient.class) {
            l = lease;
            if (l != null && System.currentTimeMillis() < l.expiresAt) return l.token;
            return login(cfg);
        }
    }

    private static String login(ProviderConfig.Vault cfg) throws ServiceException {
        String roleId = cfg.roleId != null ? cfg.roleId : outboundPassword(cfg.roleIdPassmanKey);
        String secretId = outboundPassword(cfg.secretIdPassmanKey);
        if (roleId == null || secretId == null) {
            throw new ServiceException("TokenProvider: role_id/secret_id AppRole introuvables (outbound password store)");
        }

        String body = "{\"role_id\":\"" + TemplateEngine.jsonEscape(roleId)
                + "\",\"secret_id\":\"" + TemplateEngine.jsonEscape(secretId) + "\"}";
        Map<String, String> headers = new HashMap<>();
        headers.put("Content-Type", "application/json");

        Http.Result res;
        try {
            res = Http.request(cfg.addr + "/v1/auth/" + cfg.approleMount + "/login",
                    "post", headers, body.getBytes("UTF-8"), null, null, cfg.timeoutMillis);
        } catch (java.io.UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
        if (res.status < 200 || res.status >= 300) {
            throw new ServiceException("TokenProvider: login AppRole refuse par Vault (HTTP " + res.status + ")");
        }

        IData doc = Json.parse(res.body);
        String token = Json.pathAsString(doc, "auth.client_token");
        String leaseStr = Json.pathAsString(doc, "auth.lease_duration");
        if (token == null) {
            throw new ServiceException("TokenProvider: reponse de login Vault sans client_token");
        }
        long leaseSeconds = leaseStr == null ? 0 : (long) Double.parseDouble(leaseStr);
        // lease_duration=0 = jeton sans expiration : cache 5 min, le retry-sur-403 couvre la revocation.
        long cacheMillis = leaseSeconds > 0 ? leaseSeconds * 800L : 300_000L;
        lease = new Lease(token, System.currentTimeMillis() + cacheMillis);
        return token;
    }

    private static String outboundPassword(String key) throws ServiceException {
        if (key == null) return null;
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "key", key);
        c.destroy();

        IData out;
        try {
            out = Service.doInvoke(NSName.create("pub.security.outboundPasswords:getPassword"), in);
        } catch (Exception e) {
            throw new ServiceException("TokenProvider: lecture de la cle '" + key
                    + "' impossible dans l'outbound password store (" + e.getClass().getSimpleName() + ")");
        }

        IDataCursor oc = out.getCursor();
        String result = IDataUtil.getString(oc, "result");
        String message = IDataUtil.getString(oc, "message");
        Object value = IDataUtil.get(oc, "value");
        oc.destroy();

        if (!"true".equals(result) || value == null) {
            throw new ServiceException("TokenProvider: cle '" + key + "' absente de l'outbound password store"
                    + (message == null ? "" : " (" + message + ")"));
        }
        if (value instanceof String) return (String) value;
        return convertSecureString(key, value);
    }

    /** Sortie 'value' de getPassword = WmSecureString ; conversion via le built-in dedie. */
    private static String convertSecureString(String key, Object secureString) throws ServiceException {
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "secureString", secureString);
        c.destroy();
        try {
            IData out = Service.doInvoke(NSName.create("pub.security.util:convertSecureString"), in);
            IDataCursor oc = out.getCursor();
            String s = IDataUtil.getString(oc, "string");
            oc.destroy();
            if (s == null) {
                throw new ServiceException("TokenProvider: conversion WmSecureString vide pour la cle '" + key + "'");
            }
            return s;
        } catch (ServiceException e) {
            throw e;
        } catch (Exception e) {
            throw new ServiceException("TokenProvider: conversion WmSecureString impossible pour la cle '" + key
                    + "' (" + e.getClass().getSimpleName() + ")");
        }
    }
}
