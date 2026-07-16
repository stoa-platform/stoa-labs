package wm.tokenprovider;

import com.wm.app.b2b.server.ServerAPI;
import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataUtil;

import java.io.File;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Configuration multi-provider chargee depuis le repertoire config du package :
 *   packages/&lt;PKG&gt;/config/profiles/&lt;profil&gt;.json   (un fichier par provider)
 *   packages/&lt;PKG&gt;/config/vault.json                  (connexion Vault, partagee)
 *
 * Ajouter un provider = deposer un fichier de profil + creer le secret dans
 * Vault. Aucun code. Le schema des profils est documente dans
 * config/provider.schema.json.
 *
 * Le nom de profil est valide strictement ([a-z0-9-]) : il transite par un
 * header HTTP interne et sert de nom de fichier — jamais de path traversal.
 */
public final class ProviderConfig {

    static final String PACKAGE_NAME = System.getProperty("tokenprovider.package", "TokenProvider");
    private static final Pattern SAFE_NAME = Pattern.compile("[a-z0-9][a-z0-9-]{0,63}");

    private static final ConcurrentHashMap<String, Profile> profiles = new ConcurrentHashMap<>();
    private static volatile Vault vault;

    private ProviderConfig() {}

    public static final class Profile {
        public String name;
        public String urlTemplate;
        public String method = "POST";
        public String contentType = "application/x-www-form-urlencoded";
        public String bodyTemplate;
        public Map<String, String> requestHeaders = new HashMap<>();
        public Map<String, String> params = new HashMap<>();
        public String vaultPath;
        public Map<String, String> secretMap = new HashMap<>(); // placeholder -> cle dans le secret Vault
        public String authUserVar;                              // optionnel : Basic auth sur l'appel token
        public String authPassVar;
        public String tokenPath = "access_token";
        public String expiresInPath;                            // exclusif avec fixedTtlSeconds
        public Long fixedTtlSeconds;
        public String tokenType = "Bearer";
        public int refreshSkewPercent = 80;
        public int minTtlSeconds = 30;
        public String injectHeaderName = "Authorization";
        public String injectValueTemplate = "{{tokenType}} {{token}}";
        public int timeoutMillis = 10000;
    }

    public static final class Vault {
        public String addr;
        public String approleMount = "approle";
        public String roleId;                                   // ou roleIdPassmanKey si on prefere passman
        public String roleIdPassmanKey;
        public String secretIdPassmanKey;                       // secret-zero : outbound password store IS
        public String kvMount = "secret";
        public int kvVersion = 2;
        public int cacheSecretsSeconds = 300;
        public int timeoutMillis = 5000;
    }

    public static Profile profile(String name) throws ServiceException {
        if (name == null || !SAFE_NAME.matcher(name).matches()) {
            throw new ServiceException("TokenProvider: nom de profil invalide");
        }
        Profile p = profiles.get(name);
        if (p != null) return p;
        p = loadProfile(name);
        profiles.putIfAbsent(name, p);
        return p;
    }

    public static Vault vault() throws ServiceException {
        Vault v = vault;
        if (v != null) return v;
        synchronized (ProviderConfig.class) {
            if (vault == null) vault = loadVault();
            return vault;
        }
    }

    public static void reload() {
        profiles.clear();
        vault = null;
    }

    // ------------------------------------------------------------------

    private static File configDir() {
        String override = System.getProperty("tokenprovider.config.dir");
        if (override != null) return new File(override);
        return new File(ServerAPI.getPackageConfigDir(PACKAGE_NAME).getAbsolutePath());
    }

    private static String readFile(File f) throws ServiceException {
        try {
            return new String(Files.readAllBytes(f.toPath()), "UTF-8");
        } catch (Exception e) {
            throw new ServiceException("TokenProvider: configuration introuvable ou illisible: " + f.getName());
        }
    }

    private static Profile loadProfile(String name) throws ServiceException {
        File f = new File(new File(configDir(), "profiles"), name + ".json");
        IData doc = Json.parse(readFile(f));

        Profile p = new Profile();
        p.name = name;
        IData req = (IData) Json.path(doc, "tokenRequest");
        if (req == null) throw new ServiceException("TokenProvider[" + name + "]: bloc 'tokenRequest' manquant");
        p.urlTemplate = str(req, "urlTemplate", null);
        if (p.urlTemplate == null) throw new ServiceException("TokenProvider[" + name + "]: 'tokenRequest.urlTemplate' manquant");
        p.method = str(req, "method", p.method);
        p.contentType = str(req, "contentType", p.contentType);
        p.bodyTemplate = str(req, "bodyTemplate", null);
        p.requestHeaders = map((IData) Json.path(req, "headers"));
        p.authUserVar = str(req, "authUserVar", null);
        p.authPassVar = str(req, "authPassVar", null);
        p.timeoutMillis = intval(req, "timeoutMillis", p.timeoutMillis);

        p.params = map((IData) Json.path(doc, "params"));

        IData secrets = (IData) Json.path(doc, "secrets");
        if (secrets != null) {
            p.vaultPath = str(secrets, "vaultPath", null);
            p.secretMap = map((IData) Json.path(secrets, "map"));
        }

        IData resp = (IData) Json.path(doc, "response");
        if (resp != null) {
            p.tokenPath = str(resp, "tokenPath", p.tokenPath);
            p.expiresInPath = str(resp, "expiresInPath", null);
            String fixed = str(resp, "fixedTtlSeconds", null);
            if (fixed != null) {
                try {
                    p.fixedTtlSeconds = (long) Double.parseDouble(fixed);
                } catch (NumberFormatException e) {
                    throw new ServiceException("TokenProvider[" + name + "]: valeur non numerique pour 'response.fixedTtlSeconds'");
                }
            }
            p.tokenType = str(resp, "tokenType", p.tokenType);
        }
        if (p.expiresInPath == null && p.fixedTtlSeconds == null) {
            throw new ServiceException("TokenProvider[" + name + "]: definir 'response.expiresInPath' ou 'response.fixedTtlSeconds'");
        }
        if (p.expiresInPath != null && p.fixedTtlSeconds != null) {
            throw new ServiceException("TokenProvider[" + name + "]: 'response.expiresInPath' et 'response.fixedTtlSeconds' sont exclusifs");
        }

        IData cache = (IData) Json.path(doc, "cache");
        if (cache != null) {
            p.refreshSkewPercent = intval(cache, "refreshSkewPercent", p.refreshSkewPercent);
            p.minTtlSeconds = intval(cache, "minTtlSeconds", p.minTtlSeconds);
        }

        IData inject = (IData) Json.path(doc, "inject");
        if (inject != null) {
            p.injectHeaderName = str(inject, "headerName", p.injectHeaderName);
            p.injectValueTemplate = str(inject, "valueTemplate", p.injectValueTemplate);
        }
        return p;
    }

    private static Vault loadVault() throws ServiceException {
        File f = new File(configDir(), "vault.json");
        IData doc = Json.parse(readFile(f));
        Vault v = new Vault();
        v.addr = str(doc, "addr", null);
        if (v.addr == null) throw new ServiceException("TokenProvider: 'addr' manquant dans vault.json");
        if (v.addr.endsWith("/")) v.addr = v.addr.substring(0, v.addr.length() - 1);
        IData approle = (IData) Json.path(doc, "approle");
        if (approle != null) {
            v.approleMount = str(approle, "mount", v.approleMount);
            v.roleId = str(approle, "roleId", null);
            v.roleIdPassmanKey = str(approle, "roleIdPassmanKey", null);
            v.secretIdPassmanKey = str(approle, "secretIdPassmanKey", null);
        }
        if (v.secretIdPassmanKey == null) {
            throw new ServiceException("TokenProvider: 'approle.secretIdPassmanKey' manquant dans vault.json (secret-zero dans l'outbound password store)");
        }
        IData kv = (IData) Json.path(doc, "kv");
        if (kv != null) {
            v.kvMount = str(kv, "mount", v.kvMount);
            v.kvVersion = intval(kv, "version", v.kvVersion);
        }
        v.cacheSecretsSeconds = intval(doc, "cacheSecretsSeconds", v.cacheSecretsSeconds);
        v.timeoutMillis = intval(doc, "timeoutMillis", v.timeoutMillis);
        return v;
    }

    private static String str(IData doc, String key, String def) {
        IDataCursor c = doc.getCursor();
        Object v = IDataUtil.get(c, key);
        c.destroy();
        return v == null ? def : String.valueOf(v);
    }

    private static int intval(IData doc, String key, int def) throws ServiceException {
        String s = str(doc, key, null);
        if (s == null) return def;
        try {
            return (int) Double.parseDouble(s);
        } catch (NumberFormatException e) {
            throw new ServiceException("TokenProvider: valeur non numerique pour '" + key + "'");
        }
    }

    private static Map<String, String> map(IData doc) {
        Map<String, String> out = new HashMap<>();
        if (doc == null) return out;
        IDataCursor c = doc.getCursor();
        while (c.next()) {
            Object v = c.getValue();
            if (v != null && !(v instanceof IData)) out.put(c.getKey(), String.valueOf(v));
        }
        c.destroy();
        return out;
    }
}
