package tokenPoC;

import com.wm.app.b2b.server.Service;
import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataFactory;
import com.wm.data.IDataUtil;
import com.wm.lang.ns.NSName;

import java.util.concurrent.ConcurrentHashMap;

public final class gateway {

    private static final class Entry {
        final String token;
        final long expiresAt;
        Entry(String token, long expiresAt) { this.token = token; this.expiresAt = expiresAt; }
    }

    private static final ConcurrentHashMap<String, Entry> TOKEN_CACHE = new ConcurrentHashMap<>();
    private static final long DEMO_TTL_MILLIS = 60_000L;

    /** Pattern v1 (sans cache) : pose toujours les creds. */
    public static final void setCreds(IData pipeline) throws ServiceException {
        IDataCursor pc = pipeline.getCursor();
        String apiName = IDataUtil.getString(pc, "apiName");
        Object msgCtx = IDataUtil.get(pc, "MessageContext");
        pc.destroy();
        String safe = safeName(apiName);
        setCtxVar(msgCtx, "mx:" + safe + "_user", "POC-USER-" + safe);
        setCtxVar(msgCtx, "mx:" + safe + "_password", "POC-PASS-" + safe);
    }

    /**
     * Pattern v2 (cache + condition) - stage Request :
     * cache hit  -> pose mx:<api>_token (la condition de la Custom Extension la verra non vide -> pas de callout)
     * cache miss -> pose les creds pour le callout ; declare _token pour qu'elle resolve a vide.
     */
    public static final void prepare(IData pipeline) throws ServiceException {
        IDataCursor pc = pipeline.getCursor();
        String apiName = IDataUtil.getString(pc, "apiName");
        Object msgCtx = IDataUtil.get(pc, "MessageContext");
        pc.destroy();
        String safe = safeName(apiName);

        declareCtxVar("mx:" + safe + "_token");
        Entry e = TOKEN_CACHE.get(safe);
        if (e != null && System.currentTimeMillis() < e.expiresAt) {
            setCtxVar(msgCtx, "mx:" + safe + "_token", e.token);
            System.out.println("TokenPoC prepare: CACHE HIT api=" + safe + " token=" + e.token);
            return;
        }
        System.out.println("TokenPoC prepare: CACHE MISS api=" + safe);
        setCtxVar(msgCtx, "mx:" + safe + "_user", "POC-USER-" + safe);
        setCtxVar(msgCtx, "mx:" + safe + "_password", "POC-PASS-" + safe);
    }

    /**
     * Pattern v2 - stage Response : recupere le jeton obtenu par la Custom
     * Extension et l'ecrit dans le cache JVM. Deux ponts testes :
     * (a) getContextVariable sur mx:<api>_token (variable assignee par la Transformation)
     * (b) header de reponse X-Poc-Token-Cache (assigne par la Transformation), retire avant le client.
     */
    public static final void store(IData pipeline) throws ServiceException {
        IDataCursor pc = pipeline.getCursor();
        String apiName = IDataUtil.getString(pc, "apiName");
        Object msgCtx = IDataUtil.get(pc, "MessageContext");
        IData headers = IDataUtil.getIData(pc, "headers");
        String safe = safeName(apiName);

        String token = getCtxVar(msgCtx, "mx:" + safe + "_token");
        String via = "ctxvar";
        if (token == null || token.isEmpty()) {
            token = removeHeader(headers, "X-Poc-Token-Cache");
            via = "header";
            if (headers != null) IDataUtil.put(pc, "headers", headers);
        } else if (headers != null && removeHeader(headers, "X-Poc-Token-Cache") != null) {
            IDataUtil.put(pc, "headers", headers);
        }
        pc.destroy();

        if (token == null || token.isEmpty()) {
            System.out.println("TokenPoC store: rien a stocker api=" + safe);
            return;
        }
        Entry e = TOKEN_CACHE.get(safe);
        if (e == null || !e.token.equals(token)) {
            TOKEN_CACHE.put(safe, new Entry(token, System.currentTimeMillis() + DEMO_TTL_MILLIS));
            System.out.println("TokenPoC store: STORED api=" + safe + " token=" + token + " via=" + via);
        }
    }

    // ------------------------------------------------------------------

    private static String safeName(String apiName) {
        return (apiName == null ? "unknown" : apiName).replaceAll("[^A-Za-z0-9_]", "_");
    }

    private static String removeHeader(IData headers, String name) {
        if (headers == null) return null;
        String found = null;
        IDataCursor c = headers.getCursor();
        while (c.next()) {
            if (c.getKey().equalsIgnoreCase(name)) {
                Object v = c.getValue();
                if (found == null && v != null) found = String.valueOf(v);
                c.delete();
                break;
            }
        }
        c.destroy();
        return found;
    }

    private static void declareCtxVar(String name) {
        try {
            IData ctxVar = IDataFactory.create();
            IDataCursor c = ctxVar.getCursor();
            IDataUtil.put(c, "name", name);
            IDataUtil.put(c, "schema_type", "string");
            IDataUtil.put(c, "isReadOnly", "false");
            c.destroy();
            IData din = IDataFactory.create();
            IDataCursor dc = din.getCursor();
            IDataUtil.put(dc, "ctxVar", ctxVar);
            dc.destroy();
            Service.doInvoke(NSName.create("pub.apigateway.ctxvar:declareContextVariable"), din);
        } catch (Exception ignored) {
        }
    }

    private static void setCtxVar(Object msgCtx, String name, String value) throws ServiceException {
        declareCtxVar(name);
        try {
            IData in = IDataFactory.create();
            IDataCursor c = in.getCursor();
            IDataUtil.put(c, "MessageContext", msgCtx);
            IDataUtil.put(c, "varName", name);
            IDataUtil.put(c, "serValue", value);
            c.destroy();
            Service.doInvoke(NSName.create("pub.apigateway.ctxvar:setContextVariable"), in);
        } catch (Exception e) {
            throw new ServiceException("setCtxVar(" + name + "): " + e.getClass().getSimpleName() + " " + e.getMessage());
        }
    }

    private static String getCtxVar(Object msgCtx, String name) {
        if (msgCtx == null) return null;
        try {
            IData in = IDataFactory.create();
            IDataCursor c = in.getCursor();
            IDataUtil.put(c, "MessageContext", msgCtx);
            IDataUtil.put(c, "varName", name);
            c.destroy();
            IData out = Service.doInvoke(NSName.create("pub.apigateway.ctxvar:getContextVariable"), in);
            IDataCursor oc = out.getCursor();
            Object v = IDataUtil.get(oc, "serValue");
            oc.destroy();
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }
}
