import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

type EmployeeRequest = {
  action?: unknown;
  email?: unknown;
  full_name?: unknown;
  phone?: unknown;
  address?: unknown;
  employee_code?: unknown;
  joining_date?: unknown;
  role_id?: unknown;
  password?: unknown;
  confirm_password?: unknown;
  target_user_id?: unknown;
};

type SupabaseConfig = {
  url: string;
  anonKey: string;
  serviceRoleKey: string;
};

type SupabaseConfigResult = { error: string } | { config: SupabaseConfig };

function jsonError(message: string, status: number) {
  return NextResponse.json({ error: message }, { status });
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function getSupabaseConfig(): SupabaseConfigResult {
  const publicUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serverUrl = process.env.SUPABASE_URL;
  const url = publicUrl || serverUrl;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey || !serviceRoleKey) {
    return { error: 'Employee account management is not configured on the server.' };
  }
  if (publicUrl && serverUrl) {
    try {
      if (new URL(publicUrl).origin !== new URL(serverUrl).origin) {
        return { error: 'SUPABASE_URL and NEXT_PUBLIC_SUPABASE_URL point to different projects.' };
      }
    } catch {
      return { error: 'The configured Supabase URL is invalid.' };
    }
  }
  return { config: { url, anonKey, serviceRoleKey } };
}

async function getOwnerClient(request: Request) {
  const authorization = request.headers.get('authorization');
  const accessToken = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) return { response: jsonError('Sign in as the Store Owner to continue.', 401) };

  const configResult = getSupabaseConfig();
  if ('error' in configResult) {
    return { response: jsonError(configResult.error, 503) };
  }
  const config = configResult.config;

  const client = createClient(config.url, config.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const { data: userResult, error: userError } = await client.auth.getUser(accessToken);
  if (userError || !userResult.user) {
    return { response: jsonError('Your sign-in session is invalid or expired. Please sign in again.', 401) };
  }

  const { data: isOwner, error: ownerError } = await client.rpc('is_store_owner');
  if (ownerError) {
    return {
      response: jsonError(
        'Unable to verify Store Owner access. Check the connected Supabase project, API schema cache, and employee/RBAC RPCs.',
        503
      ),
    };
  }
  if (isOwner !== true) return { response: jsonError('Only the Store Owner can manage employee accounts.', 403) };

  return { client, config };
}

export async function POST(request: Request) {
  const owner = await getOwnerClient(request);
  if (owner.response) return owner.response;

  let body: EmployeeRequest;
  try {
    body = await request.json() as EmployeeRequest;
  } catch {
    return jsonError('The request body must be valid JSON.', 400);
  }

  if (body.action === 'delete') {
    if (!isUuid(body.target_user_id)) return jsonError('A valid employee account ID is required.', 400);

    const { data: members, error: membersError } = await owner.client.rpc('get_store_team_members');
    if (membersError) {
      return jsonError('Unable to verify that this employee belongs to your store.', 503);
    }
    const member = Array.isArray(members)
      ? members.find((candidate: { user_id?: unknown }) => candidate.user_id === body.target_user_id)
      : undefined;
    if (!member) return jsonError('The employee account was not found in your store.', 404);

    const { error: suspendError } = await owner.client.rpc('manage_store_member', {
      target_user_id: body.target_user_id,
      target_status: 'suspended',
      target_role: 'cashier',
      target_permissions: ['pos'],
    });
    if (suspendError) {
      return jsonError(`Unable to disable the employee before deletion: ${suspendError.message}`, 409);
    }

    const admin = createClient(owner.config.url, owner.config.serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { error: deleteError } = await admin.auth.admin.deleteUser(body.target_user_id);
    if (deleteError) {
      return jsonError(
        `The employee was disabled, but the Auth account could not be deleted: ${deleteError.message}`,
        500
      );
    }

    return NextResponse.json({ success: true });
  }

  if (body.action !== 'create') return jsonError('Unsupported employee account operation.', 400);

  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const fullName = typeof body.full_name === 'string' ? body.full_name.trim() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const confirmPassword = typeof body.confirm_password === 'string' ? body.confirm_password : '';
  const roleId = body.role_id;
  const phone = typeof body.phone === 'string' ? body.phone.trim() : '';
  const address = typeof body.address === 'string' ? body.address.trim() : '';
  const employeeCode = typeof body.employee_code === 'string' ? body.employee_code.trim() : '';
  const joiningDate = typeof body.joining_date === 'string' ? body.joining_date : '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !fullName || !isUuid(roleId)) {
    return jsonError('A valid email, employee name, and store role are required.', 400);
  }
  if (password.length < 8 || password.length > 128) {
    return jsonError('Use a password between 8 and 128 characters.', 400);
  }
  if (password !== confirmPassword) return jsonError('The passwords do not match.', 400);
  if (joiningDate && !/^\d{4}-\d{2}-\d{2}$/.test(joiningDate)) {
    return jsonError('The joining date must be a valid calendar date.', 400);
  }

  const { data: invitationRows, error: invitationError } = await owner.client.rpc(
    'create_store_employee_invitation',
    {
      target_email: email,
      target_role_id: roleId,
      target_full_name: fullName,
      target_phone: phone || null,
      target_address: address || null,
      target_employee_code: employeeCode || null,
      target_joining_date: joiningDate || null,
    }
  );
  if (invitationError) {
    if (invitationError.code === 'PGRST202') {
      return jsonError(
        `Supabase could not resolve the employee invitation RPC. Verify the connected project, API schema cache, and RBAC migration state: ${invitationError.message}`,
        503
      );
    }
    return jsonError(invitationError.message, invitationError.code === '42501' ? 403 : 409);
  }
  const invitation = Array.isArray(invitationRows) ? invitationRows[0] : undefined;
  if (!invitation?.invitation_id || !invitation?.invitation_token) {
    return jsonError('Supabase did not return the employee invitation required for account provisioning.', 502);
  }

  const admin = createClient(owner.config.url, owner.config.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      full_name: fullName,
      phone: phone || null,
      employee_invite_token: invitation.invitation_token,
    },
  });
  if (createError || !created.user) {
    const { error: cleanupError } = await owner.client.rpc('revoke_store_invitation', {
      target_invitation_id: invitation.invitation_id,
    });
    const message = createError?.message || 'Supabase did not return the created employee account.';
    const status = createError && ['email_exists', 'user_already_exists'].includes(createError.code || '')
      ? 409
      : 400;
    return jsonError(
      cleanupError
        ? `${message} The unused invitation could not be revoked: ${cleanupError.message}`
        : message,
      status
    );
  }

  const { error: metadataError } = await admin.auth.admin.updateUserById(created.user.id, {
    user_metadata: {
      full_name: fullName,
      phone: phone || null,
      employee_invite_token: null,
    },
  });
  if (metadataError) {
    const { error: cleanupError } = await admin.auth.admin.deleteUser(created.user.id);
    return jsonError(
      cleanupError
        ? `The account was created but could not be finalized or rolled back: ${metadataError.message}; ${cleanupError.message}`
        : `Employee account setup failed and was rolled back: ${metadataError.message}`,
      500
    );
  }

  return NextResponse.json({ success: true, user_id: created.user.id }, { status: 201 });
}
