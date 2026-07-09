package wm.tokenprovider;

import com.wm.app.b2b.server.Service;
import com.wm.app.b2b.server.ServiceException;
import com.wm.data.IData;
import com.wm.data.IDataCursor;
import com.wm.data.IDataFactory;
import com.wm.data.IDataUtil;
import com.wm.lang.ns.NSName;

/**
 * Parsing JSON via le built-in pub.json:jsonStringToDocument (aucune dependance
 * externe a embarquer dans le package) + extraction par chemin pointe
 * ("access_token", "data.jwt"). Les tableaux ne sont pas supportes : si un
 * provider renvoie le jeton dans un tableau, ajouter un index simple ici.
 */
public final class Json {

    private Json() {}

    public static IData parse(String json) throws ServiceException {
        IData in = IDataFactory.create();
        IDataCursor c = in.getCursor();
        IDataUtil.put(c, "jsonString", json);
        c.destroy();
        try {
            IData out = Service.doInvoke(NSName.create("pub.json:jsonStringToDocument"), in);
            IDataCursor oc = out.getCursor();
            IData doc = IDataUtil.getIData(oc, "document");
            oc.destroy();
            if (doc == null) throw new ServiceException("TokenProvider: reponse JSON vide ou invalide");
            return doc;
        } catch (ServiceException e) {
            throw e;
        } catch (Exception e) {
            throw new ServiceException("TokenProvider: echec du parsing JSON (" + e.getClass().getSimpleName() + ")");
        }
    }

    /** Retourne la valeur au chemin pointe, ou null si absente. */
    public static Object path(IData doc, String dotPath) {
        if (doc == null || dotPath == null || dotPath.isEmpty()) return null;
        String[] parts = dotPath.split("\\.");
        Object current = doc;
        for (String part : parts) {
            if (!(current instanceof IData)) return null;
            IDataCursor c = ((IData) current).getCursor();
            current = IDataUtil.get(c, part);
            c.destroy();
        }
        return current;
    }

    public static String pathAsString(IData doc, String dotPath) {
        Object v = path(doc, dotPath);
        return v == null ? null : String.valueOf(v);
    }
}
