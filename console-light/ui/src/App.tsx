import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom';
import { useAuth } from './contexts/AuthContext';
import { Layout } from './components/Layout';
import { StoaLoader } from './vendor/stoa-shared/components/StoaLoader';

import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Contracts from './pages/Contracts';
import ContractDetail from './pages/ContractDetail';
import ContractEdit from './pages/ContractEdit';
import Promotions from './pages/Promotions';
import Subscriptions from './pages/Subscriptions';
import Audit from './pages/Audit';
import Tenants from './pages/Tenants';
import Targets from './pages/Targets';
import AdminRoles from './pages/AdminRoles';
import AdminUsers from './pages/AdminUsers';

/**
 * Garde d'authentification : pendant le traitement OIDC (callback, silent
 * renew) on affiche le loader ; non authentifié → /login (avec retour).
 */
function ProtectedLayout() {
  const { isAuthenticated, isLoading } = useAuth();
  const location = useLocation();

  if (isLoading) {
    return <StoaLoader variant="fullscreen" />;
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }

  return (
    <Layout>
      <Outlet />
    </Layout>
  );
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />

      <Route element={<ProtectedLayout />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/contracts" element={<Contracts />} />
        <Route path="/contracts/:slug" element={<ContractDetail />} />
        <Route path="/contracts/:slug/edit" element={<ContractEdit />} />
        <Route path="/promotions" element={<Promotions />} />
        <Route path="/subscriptions" element={<Subscriptions />} />
        <Route path="/audit" element={<Audit />} />
        <Route path="/tenants" element={<Tenants />} />
        <Route path="/targets" element={<Targets />} />
        <Route path="/admin/roles" element={<AdminRoles />} />
        <Route path="/admin/users" element={<AdminUsers />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
