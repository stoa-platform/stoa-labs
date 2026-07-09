package wm.tokenprovider;

import com.wm.app.b2b.server.ServiceException;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Cache de jetons par profil, en memoire JVM, avec single-flight : sous
 * charge, un seul thread va chercher le jeton, les autres attendent le
 * resultat au lieu d'empiler des appels au provider (thundering herd).
 *
 * Le TTL effectif = ttl * refreshSkewPercent / 100 (borne par minTtlSeconds) :
 * on renouvelle avant l'expiration reelle pour ne jamais router un jeton
 * peripe. Cache local par noeud IS — en cluster, chaque noeud porte au pire
 * un jeton par profil, ce qui est acceptable ; pas besoin de Terracotta.
 */
public final class TokenCache {

    public static final class Token {
        public final String value;
        public final String type;
        public final long expiresAtMillis;
        Token(String value, String type, long expiresAtMillis) {
            this.value = value; this.type = type; this.expiresAtMillis = expiresAtMillis;
        }
    }

    private static final ConcurrentHashMap<String, Token> cache = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, ReentrantLock> locks = new ConcurrentHashMap<>();

    private TokenCache() {}

    public static Token getOrFetch(String profileName) throws ServiceException {
        // Valide nom + existence du profil AVANT d'ecrire dans cache/locks :
        // le nom vient d'un header, il ne doit pas pouvoir gonfler les maps.
        ProviderConfig.Profile p = ProviderConfig.profile(profileName);

        Token t = cache.get(profileName);
        if (isValid(t)) return t;

        ReentrantLock lock = locks.computeIfAbsent(profileName, k -> new ReentrantLock());
        lock.lock();
        try {
            t = cache.get(profileName);
            if (isValid(t)) return t;

            TokenService.Result r = TokenService.fetch(profileName);
            if (r.ttlSeconds <= 0) {
                throw new ServiceException("TokenProvider[" + profileName + "]: TTL nul ou negatif renvoye par le provider");
            }

            long skewed = r.ttlSeconds * p.refreshSkewPercent / 100;
            long effectiveTtl = Math.min(r.ttlSeconds, Math.max(p.minTtlSeconds, skewed));
            Token fresh = new Token(r.token, r.tokenType,
                    System.currentTimeMillis() + effectiveTtl * 1000L);
            cache.put(profileName, fresh);
            return fresh;
        } finally {
            lock.unlock();
        }
    }

    /**
     * A appeler quand le backend repond 401 : jeton revoque ou credentials
     * tournes. Evince aussi le secret Vault du profil, sinon le refetch
     * repartirait avec l'ancien mot de passe pendant cacheSecretsSeconds.
     */
    public static void invalidate(String profileName) {
        cache.remove(profileName);
        try {
            ProviderConfig.Profile p = ProviderConfig.profile(profileName);
            VaultClient.invalidateSecret(p.vaultPath);
        } catch (Exception ignored) {
        }
    }

    public static void clear() {
        cache.clear();
    }

    private static boolean isValid(Token t) {
        return t != null && System.currentTimeMillis() < t.expiresAtMillis;
    }
}
