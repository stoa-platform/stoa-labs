package wm.tokenprovider;

import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataUtil;

import java.util.HashMap;
import java.util.Map;

/**
 * Points d'entree appeles par les policies "Invoke webMethods IS" d'API
 * Gateway (Comply to IS Spec = true, spec
 * pub.apigateway.invokeISService.specifications:RequestSpec / ResponseSpec).
 *
 * Le profil est transporte par le header interne X-Token-Profile, pose par
 * une policy Header Transformation (Add/Modify) EN AMONT — qui doit
 * l'ECRASER systematiquement (un consommateur ne doit jamais pouvoir choisir
 * le profil lui-meme). Le header est retire avant routage, y compris ses
 * doublons eventuels. Le profil est propage au stage Response via une
 * variable de contexte API Gateway (cf. ContextVar) pour l'invalidation
 * du cache sur 401.
 */
public final class GatewayAdapter {

    public static final String PROFILE_HEADER = "X-Token-Profile";

    private GatewayAdapter() {}

    /** Request Processing : resout le jeton et pose le header d'autorisation sortant. */
    public static void injectAuthHeader(IData pipeline) throws ServiceException {
        IDataCursor pc = pipeline.getCursor();
        try {
            IData headers = IDataUtil.getIData(pc, "headers");
            if (headers == null) {
                throw new ServiceException("TokenProvider: pipeline sans 'headers' — verifier 'Comply to IS Spec' sur la policy Invoke IS");
            }

            String profile = removeHeaderIgnoreCase(headers, PROFILE_HEADER);
            if (profile == null) {
                throw new ServiceException("TokenProvider: header " + PROFILE_HEADER
                        + " absent — ajouter la policy Header Transformation qui le positionne");
            }

            // Valide le nom et l'existence du profil avant tout (le header reste une entree non sure).
            ProviderConfig.Profile p = ProviderConfig.profile(profile);
            TokenCache.Token token = TokenCache.getOrFetch(profile);

            Map<String, String> vars = new HashMap<>();
            vars.put("token", token.value);
            vars.put("tokenType", token.type);
            String headerValue;
            try {
                headerValue = TemplateEngine.render(p.injectValueTemplate, vars, TemplateEngine.Mode.RAW);
            } catch (IllegalArgumentException e) {
                throw new ServiceException("TokenProvider[" + profile + "]: " + e.getMessage()
                        + " — inject.valueTemplate: " + p.injectValueTemplate);
            }
            TokenService.assertHeaderSafe(profile, p.injectHeaderName, headerValue);

            removeHeaderIgnoreCase(headers, p.injectHeaderName);
            IDataCursor hc = headers.getCursor();
            IDataUtil.put(hc, p.injectHeaderName, headerValue);
            hc.destroy();

            IDataUtil.put(pc, "headers", headers);
            // Memorise le profil pour le stage Response (invalidation sur 401).
            ContextVar.set(IDataUtil.get(pc, "MessageContext"), profile);
        } finally {
            pc.destroy();
        }
    }

    /** Response Processing (optionnel) : invalide jeton + secret si le backend rejette le jeton. */
    public static void onBackendResponse(IData pipeline) throws ServiceException {
        IDataCursor pc = pipeline.getCursor();
        try {
            Object status = IDataUtil.get(pc, "statusCode");
            if (status == null) return;

            int code;
            try {
                code = Integer.parseInt(String.valueOf(status).trim());
            } catch (NumberFormatException e) {
                return;
            }
            if (code == 401) {
                String profile = ContextVar.get(IDataUtil.get(pc, "MessageContext"));
                if (profile != null) {
                    TokenCache.invalidate(profile);
                }
            }
        } finally {
            pc.destroy();
        }
    }

    /** Service d'administration : recharge profils + vault.json et vide les caches. */
    public static void reload(IData pipeline) {
        ProviderConfig.reload();
        TokenCache.clear();
        VaultClient.invalidate();
    }

    // ------------------------------------------------------------------

    /**
     * Retire TOUTES les occurrences du header (IData accepte les cles en
     * doublon, et c.delete() repositionne le cursor : on rescanne apres
     * chaque suppression pour qu'aucun doublon ne survive).
     */
    private static String removeHeaderIgnoreCase(IData headers, String name) {
        String found = null;
        boolean removed = true;
        while (removed) {
            removed = false;
            IDataCursor c = headers.getCursor();
            while (c.next()) {
                if (c.getKey().equalsIgnoreCase(name)) {
                    Object v = c.getValue();
                    if (found == null && v != null) found = String.valueOf(v);
                    c.delete();
                    removed = true;
                    break;
                }
            }
            c.destroy();
        }
        return found;
    }
}
