package wm.tokenprovider;

import java.io.UnsupportedEncodingException;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Rendu des templates {{placeholder}} avec encodage dependant du contexte :
 * - URL  : valeurs encodees URLEncoder (query/form ; acceptable en segment de path
 *          tant que les valeurs ne contiennent pas d'espace — un realm n'en a pas)
 * - FORM : application/x-www-form-urlencoded
 * - JSON : echappement JSON des valeurs injectees dans un body JSON
 * - RAW  : aucune transformation (headers, valeur du header Authorization)
 *
 * Un placeholder non resolu leve une exception qui nomme la cle, jamais la valeur.
 */
public final class TemplateEngine {

    public enum Mode { RAW, URL, FORM, JSON }

    private static final Pattern PLACEHOLDER = Pattern.compile("\\{\\{\\s*([A-Za-z0-9_.-]+)\\s*\\}\\}");

    private TemplateEngine() {}

    public static String render(String template, Map<String, String> vars, Mode mode) {
        if (template == null) return null;
        Matcher m = PLACEHOLDER.matcher(template);
        StringBuffer out = new StringBuffer();
        while (m.find()) {
            String key = m.group(1);
            String value = vars.get(key);
            if (value == null) {
                throw new IllegalArgumentException("TokenProvider: placeholder non resolu '" + key + "'");
            }
            m.appendReplacement(out, Matcher.quoteReplacement(encode(value, mode)));
        }
        m.appendTail(out);
        return out.toString();
    }

    /** Version pour les logs : les placeholders secrets sont remplaces par ***, les autres laisses tels quels. */
    public static String redact(String template, Set<String> secretKeys) {
        if (template == null) return null;
        Matcher m = PLACEHOLDER.matcher(template);
        StringBuffer out = new StringBuffer();
        while (m.find()) {
            String key = m.group(1);
            m.appendReplacement(out, secretKeys.contains(key) ? "***" : Matcher.quoteReplacement(m.group(0)));
        }
        m.appendTail(out);
        return out.toString();
    }

    public static Mode modeForContentType(String contentType) {
        if (contentType == null) return Mode.RAW;
        String ct = contentType.toLowerCase();
        if (ct.contains("x-www-form-urlencoded")) return Mode.FORM;
        if (ct.contains("json")) return Mode.JSON;
        return Mode.RAW;
    }

    private static String encode(String value, Mode mode) {
        switch (mode) {
            case URL:
            case FORM:
                try {
                    return java.net.URLEncoder.encode(value, "UTF-8");
                } catch (UnsupportedEncodingException e) {
                    throw new IllegalStateException(e);
                }
            case JSON:
                return jsonEscape(value);
            default:
                return value;
        }
    }

    static String jsonEscape(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b");  break;
                case '\f': sb.append("\\f");  break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }
}
