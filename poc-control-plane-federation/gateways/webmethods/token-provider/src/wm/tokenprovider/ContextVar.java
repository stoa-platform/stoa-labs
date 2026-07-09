package wm.tokenprovider;

import com.wm.app.b2b.server.Service;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataFactory;
import com.wm.data.IDataUtil;
import com.wm.lang.ns.NSName;

/**
 * Variables de contexte API Gateway (pub.apigateway.ctxvar:*) : propagent le
 * nom de profil entre le stage Request (injection) et le stage Response
 * (invalidation sur 401), qui peuvent s'executer sur des threads differents.
 *
 * API documentee 10.15 ("The API for Context Variables") : les variables
 * custom DOIVENT porter le prefixe mx:, etre declarees une fois
 * (declareContextVariable, portee SESSION : posee en request, lisible en
 * response), puis lues/ecrites via get/setContextVariable avec le
 * MessageContext que RequestSpec et ResponseSpec mettent dans le pipeline.
 *
 * L'invalidation sur 401 est une optimisation (le jeton serait de toute
 * facon renouvele a son expiration) : toute erreur ici degrade en no-op
 * plutot que de faire echouer l'appel.
 */
final class ContextVar {

    static final String VAR_NAME = "mx:TOKEN_PROVIDER_PROFILE";

    private static volatile boolean declared;

    private ContextVar() {}

    static void set(Object messageContext, String value) {
        if (messageContext == null || value == null) return;
        declareOnce();
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "MessageContext", messageContext);
        IDataUtil.put(c, "varName", VAR_NAME);
        IDataUtil.put(c, "serValue", value);
        c.destroy();
        try {
            Service.doInvoke(NSName.create("pub.apigateway.ctxvar:setContextVariable"), in);
        } catch (Exception ignored) {
        }
    }

    static String get(Object messageContext) {
        if (messageContext == null) return null;
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "MessageContext", messageContext);
        IDataUtil.put(c, "varName", VAR_NAME);
        c.destroy();
        try {
            IData out = Service.doInvoke(NSName.create("pub.apigateway.ctxvar:getContextVariable"), in);
            IDataCursor oc = out.getCursor();
            Object value = IDataUtil.get(oc, "serValue");
            oc.destroy();
            return value == null ? null : String.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    /** "Once a variable has been declared it cannot be declared again" — l'echec de redeclaration est attendu apres un premier appel ou un redemarrage partiel. */
    private static void declareOnce() {
        if (declared) return;
        synchronized (ContextVar.class) {
            if (declared) return;
            IData ctxVar = IDataFactory.create();
            IDataCursor vc = ctxVar.getCursor();
            IDataUtil.put(vc, "name", VAR_NAME);
            IDataUtil.put(vc, "schema_type", "string");
            IDataUtil.put(vc, "isReadOnly", "false");
            vc.destroy();
            IData in = IDataFactory.create();
            IDataCursor c = in.getCursor();
            IDataUtil.put(c, "ctxVar", ctxVar);
            c.destroy();
            try {
                Service.doInvoke(NSName.create("pub.apigateway.ctxvar:declareContextVariable"), in);
            } catch (Exception ignored) {
            }
            declared = true;
        }
    }
}
