package wm.tokenprovider;

import com.wm.app.b2b.server.Service;
import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataFactory;
import com.wm.data.IDataUtil;
import com.wm.lang.ns.NSName;

import java.io.UnsupportedEncodingException;
import java.util.Map;

/**
 * Enveloppe de pub.client:http : on passe par le built-in (et non par
 * java.net.http) pour beneficier de la configuration IS — truststore JSSE,
 * proxy sortant, watt.net.* — sans la redupliquer.
 *
 * Le body est transmis en bytes (data/bytes) avec un Content-Type explicite,
 * ce qui evite toute ambiguite d'encodage.
 */
public final class Http {

    public static final class Result {
        public final int status;
        public final String body;
        Result(int status, String body) { this.status = status; this.body = body; }
    }

    private Http() {}

    public static Result request(String url, String method, Map<String, String> headers,
                                 byte[] body, String basicUser, String basicPass,
                                 int timeoutMillis) throws ServiceException {
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "url", url);
        IDataUtil.put(c, "method", method == null ? "post" : method.toLowerCase());
        IDataUtil.put(c, "loadAs", "bytes");
        IDataUtil.put(c, "timeout", String.valueOf(timeoutMillis));

        if (headers != null && !headers.isEmpty()) {
            IData h = IDataFactory.create();
            IDataCursor hc = h.getCursor();
            for (Map.Entry<String, String> e : headers.entrySet()) {
                IDataUtil.put(hc, e.getKey(), e.getValue());
            }
            hc.destroy();
            IDataUtil.put(c, "headers", h);
        }

        if (body != null) {
            IData data = IDataFactory.create();
            IDataCursor dc = data.getCursor();
            IDataUtil.put(dc, "bytes", body);
            dc.destroy();
            IDataUtil.put(c, "data", data);
        }

        if (basicUser != null) {
            IData auth = IDataFactory.create();
            IDataCursor ac = auth.getCursor();
            IDataUtil.put(ac, "type", "Basic");
            IDataUtil.put(ac, "user", basicUser);
            IDataUtil.put(ac, "pass", basicPass == null ? "" : basicPass);
            ac.destroy();
            IDataUtil.put(c, "auth", auth);
        }
        c.destroy();

        IData out;
        try {
            out = Service.doInvoke(NSName.create("pub.client:http"), in);
        } catch (Exception e) {
            throw new ServiceException("TokenProvider: appel HTTP impossible vers " + safeUrl(url)
                    + " (" + e.getClass().getSimpleName() + ")");
        }

        IDataCursor oc = out.getCursor();
        IData header = IDataUtil.getIData(oc, "header");
        IData bodyDoc = IDataUtil.getIData(oc, "body");
        oc.destroy();

        int status = -1;
        if (header != null) {
            IDataCursor hc = header.getCursor();
            Object s = IDataUtil.get(hc, "status");
            hc.destroy();
            if (s != null) {
                try { status = Integer.parseInt(String.valueOf(s).trim()); } catch (NumberFormatException ignored) {}
            }
        }

        String bodyString = "";
        if (bodyDoc != null) {
            IDataCursor bc = bodyDoc.getCursor();
            byte[] bytes = (byte[]) IDataUtil.get(bc, "bytes");
            bc.destroy();
            if (bytes != null) {
                try {
                    bodyString = new String(bytes, "UTF-8");
                } catch (UnsupportedEncodingException e) {
                    throw new IllegalStateException(e);
                }
            }
        }
        return new Result(status, bodyString);
    }

    /** URL sans query string ni userinfo, pour les messages d'erreur (les deux peuvent contenir des secrets). */
    static String safeUrl(String url) {
        if (url == null) return "<null>";
        String s = url;
        int q = s.indexOf('?');
        if (q >= 0) s = s.substring(0, q) + "?<redacted>";
        int scheme = s.indexOf("://");
        if (scheme >= 0) {
            int pathStart = s.indexOf('/', scheme + 3);
            int authorityEnd = pathStart >= 0 ? pathStart : s.length();
            int at = s.lastIndexOf('@', authorityEnd - 1);
            if (at >= scheme + 3) {
                s = s.substring(0, scheme + 3) + "<redacted>@" + s.substring(at + 1);
            }
        }
        return s;
    }
}
