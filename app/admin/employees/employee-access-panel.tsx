'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Copy, Edit2, KeyRound, Plus, Shield, Trash2, UserCog } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useAuth } from '@/components/providers';
import { useConfirmation } from '@/hooks/use-confirmation';
import { supabase } from '@/lib/supabase';
import {
  actionPermissions,
  permissionActions,
  permissionModules,
  permissionKeys,
  permissionsToMap,
  type PermissionMap,
} from '@/lib/rbac';
import { toast } from 'sonner';

type StoreRole = {
  id: string;
  name: string;
  description: string | null;
  role_key: string | null;
  permissions: PermissionMap | null;
  is_system: boolean;
  is_protected: boolean;
  assigned_employee_count: number;
};

type TeamMember = {
  user_id: string;
  employee_id: string | null;
  email: string;
  full_name: string | null;
  phone: string | null;
  address: string | null;
  profile_image: string | null;
  employee_code: string | null;
  joining_date: string | null;
  role: string;
  role_id: string | null;
  role_name: string | null;
  status: 'approved' | 'suspended' | 'rejected' | 'pending';
  permissions: string[];
  created_at: string;
};

type TeamInvitation = {
  invitation_id: string;
  email: string;
  role_id: string | null;
  role_name: string | null;
  full_name: string | null;
  created_at: string;
  expires_at: string;
};

type PermissionOverride = {
  permission_key: string;
  is_granted: boolean;
  is_overridden: boolean;
};

type EmployeeDraft = {
  name: string;
  phone: string;
  address: string;
  profileImage: string;
  employeeCode: string;
  joiningDate: string;
};

const emptyEmployeeDraft: EmployeeDraft = {
  name: '',
  phone: '',
  address: '',
  profileImage: '',
  employeeCode: '',
  joiningDate: '',
};

function activePermissions(role: StoreRole | undefined) {
  return Object.entries(role?.permissions || {})
    .filter(([, enabled]) => enabled)
    .map(([key]) => key);
}

function permissionSummary(role: StoreRole | undefined) {
  const permissions = activePermissions(role);
  return permissions.length ? `${permissions.length} permissions` : 'No permissions';
}

function getLoadErrorMessage(error: unknown) {
  const details = error && typeof error === 'object'
    ? error as { code?: unknown; message?: unknown }
    : null;
  const message = typeof details?.message === 'string' ? details.message : '';

  if (
    (details?.code === 'PGRST202' || /get_store_roles/i.test(message)) &&
    /get_store_roles/i.test(message)
  ) {
    return 'Supabase could not resolve the get_store_roles() RPC. The app may be connected to a different project, its API schema cache may be stale, or the RBAC migration may be missing. Verify the app Supabase URL and migration state before retrying.';
  }

  return message || 'Unable to load employee management data.';
}

export default function EmployeeAccessPanel() {
  const { profile } = useAuth();
  const { confirmAction, dialog: confirmationDialog } = useConfirmation();
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([]);
  const [invitations, setInvitations] = useState<TeamInvitation[]>([]);
  const [roles, setRoles] = useState<StoreRole[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRoleId, setInviteRoleId] = useState('');
  const [inviteDraft, setInviteDraft] = useState<EmployeeDraft>(emptyEmployeeDraft);
  const [invitePassword, setInvitePassword] = useState('');
  const [inviteConfirmPassword, setInviteConfirmPassword] = useState('');
  const [creatingInvite, setCreatingInvite] = useState(false);
  const [roleEditorOpen, setRoleEditorOpen] = useState(false);
  const [editingRole, setEditingRole] = useState<StoreRole | null>(null);
  const [roleName, setRoleName] = useState('');
  const [roleDescription, setRoleDescription] = useState('');
  const [rolePermissions, setRolePermissions] = useState<PermissionMap>({});
  const [roleNameDialogOpen, setRoleNameDialogOpen] = useState(false);
  const [employeeEditor, setEmployeeEditor] = useState<TeamMember | null>(null);
  const [employeeDraft, setEmployeeDraft] = useState<EmployeeDraft>(emptyEmployeeDraft);
  const [permissionEditor, setPermissionEditor] = useState<TeamMember | null>(null);
  const [overrides, setOverrides] = useState<PermissionOverride[]>([]);
  const [originalOverrides, setOriginalOverrides] = useState<PermissionOverride[]>([]);
  const [activityEmployee, setActivityEmployee] = useState<TeamMember | null>(null);
  const [activity, setActivity] = useState<Array<{
    id: number;
    action: string;
    module: string;
    previous_value: Record<string, unknown> | null;
    new_value: Record<string, unknown> | null;
    created_at: string;
  }>>([]);

  const loadTeam = useCallback(async () => {
    setLoading(true);
    setErrorMessage(null);
    try {
      const [membersResult, invitationsResult, rolesResult] = await Promise.all([
        supabase.rpc('get_store_team_members'),
        supabase.rpc('get_store_invitations'),
        supabase.rpc('get_store_roles'),
      ]);
      const failed = [membersResult, invitationsResult, rolesResult].find((result) => result.error);
      if (failed?.error) throw failed.error;
      setTeamMembers((membersResult.data || []) as TeamMember[]);
      setInvitations((invitationsResult.data || []) as TeamInvitation[]);
      setRoles((rolesResult.data || []) as StoreRole[]);
    } catch (error) {
      setErrorMessage(getLoadErrorMessage(error));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadTeam();
  }, [loadTeam]);

  const assignableRoles = useMemo(() => roles.filter((role) => !role.is_protected), [roles]);
  const filteredMembers = useMemo(() => {
    const search = query.trim().toLocaleLowerCase();
    return teamMembers.filter((member) => {
      const matchesSearch = !search || [
        member.full_name,
        member.email,
        member.phone,
        member.employee_code,
        member.role_name,
      ].some((value) => value?.toLocaleLowerCase().includes(search));
      const matchesStatus = statusFilter === 'all' || member.status === statusFilter;
      return matchesSearch && matchesStatus;
    });
  }, [query, statusFilter, teamMembers]);

  const createEmployee = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!inviteRoleId) {
      toast.error('Choose an employee role.');
      return;
    }
    if (invitePassword.length < 8) {
      toast.error('Use a password with at least 8 characters.');
      return;
    }
    if (invitePassword !== inviteConfirmPassword) {
      toast.error('The passwords do not match.');
      return;
    }
    setCreatingInvite(true);
    try {
      const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
      if (sessionError) throw sessionError;
      if (!sessionData.session?.access_token) throw new Error('Your sign-in session has expired. Please sign in again.');

      const response = await fetch('/api/admin/employees', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${sessionData.session.access_token}`,
        },
        body: JSON.stringify({
          action: 'create',
          email: inviteEmail,
          full_name: inviteDraft.name,
          phone: inviteDraft.phone,
          address: inviteDraft.address,
          employee_code: inviteDraft.employeeCode,
          joining_date: inviteDraft.joiningDate || null,
          role_id: inviteRoleId,
          password: invitePassword,
          confirm_password: inviteConfirmPassword,
        }),
      });
      const result = await response.json() as { error?: string };
      if (!response.ok) throw new Error(result.error || 'Unable to create the employee account.');
      toast.success('Employee account created. The employee can sign in now.');
      setInviteOpen(false);
      setInviteEmail('');
      setInviteDraft(emptyEmployeeDraft);
      setInvitePassword('');
      setInviteConfirmPassword('');
      await loadTeam();
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Unable to create the employee account.');
    } finally {
      setCreatingInvite(false);
    }
  };

  const deleteMember = async (member: TeamMember) => {
    await confirmAction({
      title: 'Delete employee account',
      description: `Permanently remove the sign-in account for ${member.full_name || member.email}? Historical employee and transaction records will be retained.`,
      confirmLabel: 'Delete account',
      destructive: true,
      successMessage: 'Employee account deleted. Historical records were retained.',
      action: async () => {
        const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
        if (sessionError) throw sessionError;
        if (!sessionData.session?.access_token) throw new Error('Your sign-in session has expired. Please sign in again.');

        const response = await fetch('/api/admin/employees', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${sessionData.session.access_token}`,
          },
          body: JSON.stringify({ action: 'delete', target_user_id: member.user_id }),
        });
        const result = await response.json() as { error?: string };
        if (!response.ok) throw new Error(result.error || 'Unable to delete the employee account.');
        await loadTeam();
      },
    });
  };

  const revokeInvitation = async (invitation: TeamInvitation) => {
    await confirmAction({
      title: 'Revoke invitation',
      description: `Revoke the invitation for ${invitation.email}?`,
      confirmLabel: 'Revoke',
      destructive: true,
      successMessage: 'Invitation revoked.',
      action: async () => {
        const { error } = await supabase.rpc('revoke_store_invitation', {
          target_invitation_id: invitation.invitation_id,
        });
        if (error) throw error;
        await loadTeam();
      },
    });
  };

  const openRoleEditor = (role: StoreRole) => {
    setEditingRole(role);
    setRoleName(role.name);
    setRoleDescription(role.description || '');
    setRolePermissions({ ...(role.permissions || {}) });
    setRoleEditorOpen(true);
  };

  const saveRole = async () => {
    if (!editingRole) return;
    const permissions = Object.fromEntries(
      Object.entries(rolePermissions).filter(([, enabled]) => enabled)
    );
    await confirmAction({
      title: 'Save role permissions',
      description: `Apply the updated permissions for ${roleName.trim()} to every employee assigned to this role?`,
      confirmLabel: 'Save changes',
      successMessage: 'Role permissions saved.',
      action: async () => {
        const { error } = await supabase.rpc('manage_store_role', {
          operation: 'update',
          target_role_id: editingRole.id,
          target_name: roleName.trim(),
          target_description: roleDescription.trim() || null,
          target_permissions: permissions,
          source_role_id: null,
        });
        if (error) throw error;
        setRoleEditorOpen(false);
        await loadTeam();
      },
    });
  };

  const createRole = async (duplicate?: StoreRole, requestedName?: string) => {
    const name = (requestedName ?? roleName).trim();
    if (!name) {
      toast.error('Enter a role name.');
      return;
    }
    const { error } = await supabase.rpc('manage_store_role', {
      operation: duplicate ? 'duplicate' : 'create',
      target_role_id: null,
      target_name: name,
      target_description: (duplicate?.description ?? roleDescription).trim() || null,
      target_permissions: null,
      source_role_id: duplicate?.id || null,
    });
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(duplicate ? 'Role duplicated.' : 'Role created.');
    setRoleNameDialogOpen(false);
    setRoleName('');
    setRoleDescription('');
    await loadTeam();
  };

  const deleteRole = async (role: StoreRole) => {
    await confirmAction({
      title: 'Delete role',
      description: `Delete ${role.name}? Only unused custom roles can be deleted.`,
      confirmLabel: 'Delete role',
      destructive: true,
      successMessage: 'Role deleted.',
      action: async () => {
        const { error } = await supabase.rpc('manage_store_role', {
          operation: 'delete',
          target_role_id: role.id,
          target_name: null,
          target_description: null,
          target_permissions: null,
          source_role_id: null,
        });
        if (error) throw error;
        await loadTeam();
      },
    });
  };

  const changeMemberRole = async (member: TeamMember, roleId: string) => {
    const role = roles.find((item) => item.id === roleId);
    if (!role) return;
    const permissions = activePermissions(role).map((key) => key.replaceAll('.', ' '));
    await confirmAction({
      title: 'Change employee role',
      description: `Assign ${role.name} to ${member.full_name || member.email}? This role grants: ${permissions.join(', ') || 'no permissions'}.`,
      confirmLabel: 'Assign role',
      successMessage: 'Employee role updated.',
      action: async () => {
        const { error } = await supabase.rpc('manage_store_member', {
          target_user_id: member.user_id,
          target_status: member.status,
          target_role: role.role_key || role.name,
          target_permissions: null,
        });
        if (error) throw error;
        await loadTeam();
      },
    });
  };

  const changeMemberStatus = async (member: TeamMember) => {
    const nextStatus = member.status === 'approved' ? 'suspended' : 'approved';
    await confirmAction({
      title: nextStatus === 'approved' ? 'Activate employee' : 'Deactivate employee',
      description: `${nextStatus === 'approved' ? 'Activate' : 'Deactivate'} ${member.full_name || member.email}?`,
      confirmLabel: nextStatus === 'approved' ? 'Activate' : 'Deactivate',
      destructive: nextStatus !== 'approved',
      successMessage: nextStatus === 'approved' ? 'Employee activated.' : 'Employee deactivated.',
      action: async () => {
        const role = roles.find((item) => item.id === member.role_id);
        const { error } = await supabase.rpc('manage_store_member', {
          target_user_id: member.user_id,
          target_status: nextStatus,
          target_role: role?.role_key || role?.name || null,
          target_permissions: null,
        });
        if (error) throw error;
        await loadTeam();
      },
    });
  };

  const saveEmployee = async () => {
    if (!employeeEditor) return;
    await confirmAction({
      title: 'Save employee details',
      description: `Save the profile changes for ${employeeEditor.full_name || employeeEditor.email}?`,
      confirmLabel: 'Save changes',
      successMessage: 'Employee details updated.',
      action: async () => {
        const { error } = await supabase.rpc('update_store_employee', {
          target_user_id: employeeEditor.user_id,
          target_full_name: employeeDraft.name.trim(),
          target_phone: employeeDraft.phone || null,
          target_address: employeeDraft.address || null,
          target_profile_image: employeeDraft.profileImage || null,
          target_employee_code: employeeDraft.employeeCode || null,
          target_joining_date: employeeDraft.joiningDate || null,
        });
        if (error) throw error;
        setEmployeeEditor(null);
        await loadTeam();
      },
    });
  };

  const sendPasswordReset = async (member: TeamMember) => {
    const { error } = await supabase.auth.resetPasswordForEmail(member.email, {
      redirectTo: `${window.location.origin}/auth/callback?flow=recovery`,
    });
    if (error) toast.error(error.message);
    else toast.success(`Password reset link sent to ${member.email}.`);
  };

  const openPermissionEditor = async (member: TeamMember) => {
    const { data, error } = await supabase.rpc('get_store_employee_permissions', {
      target_user_id: member.user_id,
    });
    if (error) {
      toast.error(error.message);
      return;
    }
    const loadedOverrides = (data || []) as PermissionOverride[];
    setOverrides(loadedOverrides);
    setOriginalOverrides(loadedOverrides);
    setPermissionEditor(member);
  };

  const saveOverrides = async () => {
    if (!permissionEditor) return;
    const originalByKey = new Map(originalOverrides.map((item) => [item.permission_key, item]));
    const changedOverrides = Object.fromEntries(overrides.flatMap((item) => {
      const currentState = item.is_overridden ? item.is_granted ? 'allow' : 'deny' : 'inherit';
      const original = originalByKey.get(item.permission_key);
      const originalState = original?.is_overridden ? original.is_granted ? 'allow' : 'deny' : 'inherit';
      return currentState === originalState ? [] : [[item.permission_key, currentState]];
    }));
    await confirmAction({
      title: 'Save individual permissions',
      description: `Apply the individual permission overrides for ${permissionEditor.full_name || permissionEditor.email}?`,
      confirmLabel: 'Save overrides',
      successMessage: 'Individual permissions saved.',
      action: async () => {
        const { error } = await supabase.rpc('set_store_employee_permission_overrides', {
          target_user_id: permissionEditor.user_id,
          target_overrides: changedOverrides,
        });
        if (error) throw error;
        setPermissionEditor(null);
        await loadTeam();
      },
    });
  };

  const loadActivity = async (member: TeamMember) => {
    const { data, error } = await supabase.rpc('get_store_employee_activity', {
      target_user_id: member.user_id,
    });
    if (error) {
      toast.error(error.message);
      return;
    }
    setActivity((data || []) as typeof activity);
    setActivityEmployee(member);
  };

  if (profile?.role !== 'admin' && profile?.role !== 'store_owner') return null;

  return (
    <div className="space-y-6">
      {errorMessage && (
        <div
          role="alert"
          className="rounded-md border border-amber-500/40 bg-amber-50 p-3 text-sm text-amber-950 dark:bg-amber-950/30 dark:text-amber-100"
        >
          {errorMessage}
        </div>
      )}

      <Card className="space-y-5 p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-xl font-bold font-heading">Employees</h2>
            <p className="text-sm text-muted-foreground">Manage employee accounts, store roles, and access.</p>
          </div>
          <Button onClick={() => {
            setInviteRoleId(assignableRoles.find((role) => role.role_key === 'cashier')?.id || assignableRoles[0]?.id || '');
            setInviteOpen(true);
          }}>
            <Plus className="mr-2 h-4 w-4" /> Add employee
          </Button>
        </div>

        <div className="grid gap-3 sm:grid-cols-3">
          <Input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search name, email, phone, ID..." />
          <select className="h-10 rounded-md border bg-background px-3 text-sm" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
            <option value="all">All account statuses</option>
            <option value="approved">Active</option>
            <option value="suspended">Inactive</option>
            <option value="pending">Pending</option>
            <option value="rejected">Rejected</option>
          </select>
          <div className="flex items-center text-sm text-muted-foreground">
            {teamMembers.length} employee account{teamMembers.length === 1 ? '' : 's'}
          </div>
        </div>

        {loading ? <p className="text-sm text-muted-foreground">Loading employees...</p> :
          filteredMembers.length === 0 ? <p className="text-sm text-muted-foreground">No employee accounts found.</p> :
          <div className="space-y-3">
            {filteredMembers.map((member) => {
              const role = roles.find((item) => item.id === member.role_id);
              return (
                <div key={member.user_id} className="space-y-3 rounded-lg border p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="flex min-w-0 items-start gap-3">
                      {member.profile_image ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={member.profile_image} alt="" className="h-10 w-10 rounded-full object-cover" />
                      ) : (
                        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-muted">
                          <UserCog className="h-5 w-5 text-muted-foreground" />
                        </div>
                      )}
                      <div className="min-w-0">
                        <p className="font-semibold">{member.full_name || member.email}</p>
                        <p className="break-all text-xs text-muted-foreground">
                          {member.email}{member.phone ? ` · ${member.phone}` : ''}
                          {member.employee_code ? ` · ID ${member.employee_code}` : ''}
                        </p>
                        <div className="mt-1 flex flex-wrap items-center gap-2">
                          <Badge variant="outline">{member.role_name || 'Legacy role'}</Badge>
                          <Badge variant={member.status === 'approved' ? 'default' : 'secondary'}>
                            {member.status === 'approved' ? 'Active' : member.status}
                          </Badge>
                          <span className="text-xs text-muted-foreground">{permissionSummary(role)}</span>
                        </div>
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      <Button size="sm" variant="outline" onClick={() => {
                        setEmployeeEditor(member);
                        setEmployeeDraft({
                          name: member.full_name || '',
                          phone: member.phone || '',
                          address: member.address || '',
                          profileImage: member.profile_image || '',
                          employeeCode: member.employee_code || '',
                          joiningDate: member.joining_date || '',
                        });
                      }}><Edit2 className="mr-1 h-3.5 w-3.5" /> Edit</Button>
                      <Button size="sm" variant="outline" onClick={() => void sendPasswordReset(member)}>
                        <KeyRound className="mr-1 h-3.5 w-3.5" /> Reset password
                      </Button>
                      <Button size="sm" variant="outline" onClick={() => void loadActivity(member)}>Activity</Button>
                      <Button size="sm" variant="outline" className="text-destructive" onClick={() => void deleteMember(member)}>
                        <Trash2 className="mr-1 h-3.5 w-3.5" /> Delete account
                      </Button>
                      <Button size="sm" variant={member.status === 'approved' ? 'destructive' : 'default'} onClick={() => void changeMemberStatus(member)}>
                        {member.status === 'approved' ? 'Deactivate' : 'Activate'}
                      </Button>
                    </div>
                  </div>

                  <div className="grid gap-3 border-t pt-3 sm:grid-cols-[minmax(12rem,1fr)_auto] sm:items-end">
                    <div className="space-y-1">
                      <Label htmlFor={`role-${member.user_id}`}>Assigned role</Label>
                      <select id={`role-${member.user_id}`} className="h-10 w-full rounded-md border bg-background px-3 text-sm"
                        value={member.role_id || ''} onChange={(event) => void changeMemberRole(member, event.target.value)}>
                        <option value="" disabled>Select role</option>
                        {assignableRoles.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
                      </select>
                    </div>
                    <Button size="sm" variant="outline" onClick={() => void openPermissionEditor(member)}>
                      <Shield className="mr-2 h-4 w-4" /> Individual permissions
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>}
      </Card>

      <Card className="space-y-4 p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-xl font-bold font-heading">Store roles</h2>
            <p className="text-sm text-muted-foreground">Role permission updates apply to all assigned employees.</p>
          </div>
          <Button variant="outline" onClick={() => {
            setRoleName('');
            setRoleDescription('');
            setRoleNameDialogOpen(true);
          }}><Plus className="mr-2 h-4 w-4" /> Create custom role</Button>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {roles.map((role) => (
            <div key={role.id} className="space-y-3 rounded-lg border p-4">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <p className="font-semibold">{role.name}</p>
                  <p className="text-xs text-muted-foreground">{role.description || 'No description'}</p>
                </div>
                {role.is_protected && <Badge variant="secondary">Protected</Badge>}
              </div>
              <div className="flex items-center justify-between text-xs text-muted-foreground">
                <span>{role.assigned_employee_count} assigned</span>
                <span>{permissionSummary(role)}</span>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button size="sm" variant="outline" onClick={() => openRoleEditor(role)}>Edit permissions</Button>
                <Button size="sm" variant="outline" onClick={() => {
                  void createRole(role, `${role.name} Copy`);
                }}><Copy className="mr-1 h-3.5 w-3.5" /> Duplicate</Button>
                {!role.is_system && !role.is_protected && (
                  <Button size="sm" variant="ghost" className="text-destructive" onClick={() => void deleteRole(role)}>
                    <Trash2 className="mr-1 h-3.5 w-3.5" /> Delete
                  </Button>
                )}
              </div>
            </div>
          ))}
        </div>
      </Card>

      {invitations.length > 0 && (
        <Card className="space-y-3 p-5">
          <h2 className="font-semibold">Pending invitations</h2>
          {invitations.map((invitation) => (
            <div key={invitation.invitation_id} className="flex flex-wrap items-center justify-between gap-3 rounded-md border p-3">
              <div>
                <p className="font-medium">{invitation.full_name || invitation.email} · {invitation.role_name || 'Employee'}</p>
                <p className="text-xs text-muted-foreground">{invitation.email} · Expires {new Date(invitation.expires_at).toLocaleString()}</p>
              </div>
              <Button size="sm" variant="outline" onClick={() => void revokeInvitation(invitation)}>Revoke</Button>
            </div>
          ))}
        </Card>
      )}

      <Dialog open={inviteOpen} onOpenChange={(open) => {
        setInviteOpen(open);
        if (!open) {
          setInvitePassword('');
          setInviteConfirmPassword('');
        }
      }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Create employee account</DialogTitle></DialogHeader>
          <form onSubmit={createEmployee} className="space-y-4">
            <div className="space-y-2"><Label>Email</Label><Input type="email" required value={inviteEmail} onChange={(event) => setInviteEmail(event.target.value)} /></div>
            <div className="space-y-2"><Label>Full name</Label><Input required value={inviteDraft.name} onChange={(event) => setInviteDraft({ ...inviteDraft, name: event.target.value })} /></div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2"><Label>Phone</Label><Input value={inviteDraft.phone} onChange={(event) => setInviteDraft({ ...inviteDraft, phone: event.target.value })} /></div>
              <div className="space-y-2"><Label>Employee ID</Label><Input value={inviteDraft.employeeCode} onChange={(event) => setInviteDraft({ ...inviteDraft, employeeCode: event.target.value })} /></div>
            </div>
            <div className="space-y-2"><Label>Address</Label><Input value={inviteDraft.address} onChange={(event) => setInviteDraft({ ...inviteDraft, address: event.target.value })} /></div>
            <div className="space-y-2">
              <Label>Role</Label>
              <select className="h-10 w-full rounded-md border bg-background px-3 text-sm" value={inviteRoleId} onChange={(event) => setInviteRoleId(event.target.value)}>
                {assignableRoles.map((role) => <option key={role.id} value={role.id}>{role.name}</option>)}
              </select>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2"><Label htmlFor="employee-initial-password">Initial password</Label><Input id="employee-initial-password" type="password" autoComplete="new-password" minLength={8} maxLength={128} required value={invitePassword} onChange={(event) => setInvitePassword(event.target.value)} /></div>
              <div className="space-y-2"><Label htmlFor="employee-confirm-password">Confirm password</Label><Input id="employee-confirm-password" type="password" autoComplete="new-password" minLength={8} maxLength={128} required value={inviteConfirmPassword} onChange={(event) => setInviteConfirmPassword(event.target.value)} /></div>
            </div>
            {inviteRoleId && <div className="rounded-md bg-muted p-3">
              <p className="mb-1 text-xs font-medium">Permissions granted by {roles.find((role) => role.id === inviteRoleId)?.name}</p>
              <p className="text-xs text-muted-foreground">
                {activePermissions(roles.find((role) => role.id === inviteRoleId)).map((key) => key.replaceAll('.', ' ')).join(', ') || 'This role currently grants no permissions.'}
              </p>
            </div>}
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setInviteOpen(false)}>Cancel</Button>
              <Button type="submit" disabled={creatingInvite || !inviteRoleId}>{creatingInvite ? 'Creating...' : 'Create account'}</Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog open={roleNameDialogOpen} onOpenChange={setRoleNameDialogOpen}>
        <DialogContent>
          <DialogHeader><DialogTitle>Create custom role</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2"><Label>Role name</Label><Input value={roleName} onChange={(event) => setRoleName(event.target.value)} /></div>
            <div className="space-y-2"><Label>Description</Label><Input value={roleDescription} onChange={(event) => setRoleDescription(event.target.value)} /></div>
          </div>
          <DialogFooter><Button variant="outline" onClick={() => setRoleNameDialogOpen(false)}>Cancel</Button><Button onClick={() => void createRole()}>Create role</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={roleEditorOpen} onOpenChange={setRoleEditorOpen}>
        <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
          <DialogHeader><DialogTitle>Edit permissions · {editingRole?.name}</DialogTitle></DialogHeader>
          <div className="space-y-4">
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2"><Label>Role name</Label><Input value={roleName} onChange={(event) => setRoleName(event.target.value)} disabled={editingRole?.is_protected} /></div>
              <div className="space-y-2"><Label>Description</Label><Input value={roleDescription} onChange={(event) => setRoleDescription(event.target.value)} /></div>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button type="button" size="sm" variant="outline" onClick={() => setRolePermissions(permissionsToMap(permissionKeys))}>Select all</Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setRolePermissions({})}>Deselect all</Button>
              <span className="self-center text-xs text-muted-foreground">Changes take effect for every employee assigned to this role.</span>
            </div>
            <div className="grid gap-3 md:grid-cols-2">
              {permissionModules.map((module) => {
                const keys = permissionActions.map(({ key }) => `${module.key}.${key}`);
                const allSelected = keys.every((key) => Boolean(rolePermissions[key]));
                return (
                  <details key={module.key} className="rounded-md border p-3">
                    <summary className="flex cursor-pointer list-none items-center justify-between gap-3 font-medium">
                      <span>{module.label}</span>
                      <label className="flex items-center gap-2 text-xs font-normal text-muted-foreground" onClick={(event) => event.stopPropagation()}>
                        <input type="checkbox" checked={allSelected} onChange={(event) => {
                          const next = { ...rolePermissions };
                          keys.forEach((key) => { if (event.target.checked) next[key] = true; else delete next[key]; });
                          setRolePermissions(next);
                        }} /> Select module
                      </label>
                    </summary>
                    <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
                      {permissionActions.map((action) => {
                        const key = `${module.key}.${action.key}`;
                        return <label key={key} className="flex items-center gap-2 text-sm">
                          <input type="checkbox" checked={Boolean(rolePermissions[key])} onChange={(event) => setRolePermissions({
                            ...rolePermissions,
                            [key]: event.target.checked,
                          })} />
                          {action.label}
                        </label>;
                      })}
                    </div>
                  </details>
                );
              })}
            </div>
            <section className="space-y-2 rounded-md border p-3">
              <h3 className="font-medium">Action-level permissions</h3>
              <div className="grid gap-2 sm:grid-cols-2">
                {actionPermissions.map((action) => <label key={action.key} className="flex items-center gap-2 text-sm">
                  <input type="checkbox" checked={Boolean(rolePermissions[action.key])} onChange={(event) => setRolePermissions({
                    ...rolePermissions,
                    [action.key]: event.target.checked,
                  })} />
                  {action.label}
                </label>)}
              </div>
            </section>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRoleEditorOpen(false)}>Cancel</Button>
            <Button onClick={() => void saveRole()}>Save changes</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(employeeEditor)} onOpenChange={(open) => { if (!open) setEmployeeEditor(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Edit employee profile</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2"><Label>Full name</Label><Input value={employeeDraft.name} onChange={(event) => setEmployeeDraft({ ...employeeDraft, name: event.target.value })} /></div>
            <div className="space-y-2"><Label>Phone</Label><Input value={employeeDraft.phone} onChange={(event) => setEmployeeDraft({ ...employeeDraft, phone: event.target.value })} /></div>
            <div className="space-y-2"><Label>Address</Label><Input value={employeeDraft.address} onChange={(event) => setEmployeeDraft({ ...employeeDraft, address: event.target.value })} /></div>
            <div className="space-y-2"><Label>Profile image URL</Label><Input value={employeeDraft.profileImage} onChange={(event) => setEmployeeDraft({ ...employeeDraft, profileImage: event.target.value })} /></div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2"><Label>Employee ID</Label><Input value={employeeDraft.employeeCode} onChange={(event) => setEmployeeDraft({ ...employeeDraft, employeeCode: event.target.value })} /></div>
              <div className="space-y-2"><Label>Joining date</Label><Input type="date" value={employeeDraft.joiningDate} onChange={(event) => setEmployeeDraft({ ...employeeDraft, joiningDate: event.target.value })} /></div>
            </div>
          </div>
          <DialogFooter><Button variant="outline" onClick={() => setEmployeeEditor(null)}>Cancel</Button><Button onClick={() => void saveEmployee()}>Save changes</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(permissionEditor)} onOpenChange={(open) => { if (!open) setPermissionEditor(null); }}>
        <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
          <DialogHeader><DialogTitle>Individual permissions · {permissionEditor?.full_name || permissionEditor?.email}</DialogTitle></DialogHeader>
          <p className="text-sm text-muted-foreground">Choose Allow, Deny, or Inherit for each permission. Deny overrides the assigned role.</p>
          <div className="space-y-3">
            {permissionModules.map((module) => <details key={module.key} className="rounded-md border p-3">
              <summary className="cursor-pointer font-medium">{module.label}</summary>
              <div className="mt-3 grid gap-2 sm:grid-cols-2">
                {permissionActions.map((action) => {
                  const key = `${module.key}.${action.key}`;
                  const override = overrides.find((item) => item.permission_key === key);
                  return <PermissionOverrideControl key={key} label={action.label} value={
                    override?.is_overridden ? override.is_granted ? 'allow' : 'deny' : 'inherit'
                  } onChange={(value) => setOverrides((current) => current.map((item) =>
                    item.permission_key === key
                      ? { ...item, is_overridden: value !== 'inherit', is_granted: value === 'allow' }
                      : item
                  ))} />;
                })}
              </div>
            </details>)}
            <section className="space-y-2 rounded-md border p-3">
              <h3 className="font-medium">Action-level permissions</h3>
              <div className="grid gap-2 sm:grid-cols-2">
                {actionPermissions.map((action) => {
                  const override = overrides.find((item) => item.permission_key === action.key);
                  return <PermissionOverrideControl key={action.key} label={action.label} value={
                    override?.is_overridden ? override.is_granted ? 'allow' : 'deny' : 'inherit'
                  } onChange={(value) => setOverrides((current) => current.map((item) =>
                    item.permission_key === action.key
                      ? { ...item, is_overridden: value !== 'inherit', is_granted: value === 'allow' }
                      : item
                  ))} />;
                })}
              </div>
            </section>
          </div>
          <DialogFooter><Button variant="outline" onClick={() => setPermissionEditor(null)}>Cancel</Button><Button onClick={() => void saveOverrides()}>Save overrides</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(activityEmployee)} onOpenChange={(open) => { if (!open) setActivityEmployee(null); }}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader><DialogTitle>Activity · {activityEmployee?.full_name || activityEmployee?.email}</DialogTitle></DialogHeader>
          {activity.length === 0 ? <p className="text-sm text-muted-foreground">No activity recorded yet.</p> :
            <div className="space-y-2">{activity.map((item) => <div key={item.id} className="rounded-md border p-3">
              <p className="font-medium">{item.action.replaceAll('_', ' ')} · {item.module}</p>
              <p className="text-xs text-muted-foreground">{new Date(item.created_at).toLocaleString()}</p>
            </div>)}</div>}
        </DialogContent>
      </Dialog>

      {confirmationDialog}
    </div>
  );
}

function PermissionOverrideControl({
  label,
  value,
  onChange,
}: {
  label: string;
  value: 'inherit' | 'allow' | 'deny';
  onChange: (value: 'inherit' | 'allow' | 'deny') => void;
}) {
  return (
    <label className="flex items-center justify-between gap-2 text-sm">
      <span>{label}</span>
      <select className="h-8 rounded-md border bg-background px-2 text-xs" value={value}
        onChange={(event) => onChange(event.target.value as 'inherit' | 'allow' | 'deny')}>
        <option value="inherit">Inherit</option>
        <option value="allow">Allow</option>
        <option value="deny">Deny</option>
      </select>
    </label>
  );
}
