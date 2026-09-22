-- NODEX bootstrap administrator.
--
-- Creates the first principal on a project that has no mail delivery and
-- therefore cannot use the dashboard invite flow: a Supabase Auth user plus the
-- matching administrative invite, in the order the provisioning trigger
-- requires. Everything the trigger owns (app_users, membership, audit event) is
-- produced by the trigger, not by this script — writing those rows directly
-- would leave an unaudited privilege grant.
--
-- Run with psql (the password never appears in this file):
--
--   set nodex.bootstrap_password = 'a-long-throwaway-password';
--   \i supabase/bootstrap/bootstrap_admin.sql
--
-- Overridables, same mechanism:
--   nodex.bootstrap_admin_email   (default admin@nodex.local)
--   nodex.bootstrap_admin_name    (default Nodex Bootstrap Administrator)
--   nodex.bootstrap_tenant_id     (default 10000000-0000-4000-8000-000000000001)
--   nodex.bootstrap_role_key      (default hospital_super_admin)
--
-- The script is idempotent: an existing invite or an existing Auth user is left
-- alone, and an existing password is never overwritten, so re-running it after
-- the administrator has rotated their credentials is safe.
--
-- Three Auth details are load-bearing, learned the hard way:
--   * auth.identities.email is a generated column — it must not be inserted.
--   * GoTrue scans confirmation_token / recovery_token / email_change /
--     email_change_token_new as strings. A row that leaves them NULL makes every
--     password grant fail with 500 before any credential comparison happens.
--   * auth.users and auth.identities must be created together, or a failure
--     between them leaves an account that exists but cannot be looked up.

do $bootstrap$
declare
  v_password   text := nullif(current_setting('nodex.bootstrap_password', true), '');
  v_email      text := lower(coalesce(
                          nullif(current_setting('nodex.bootstrap_admin_email', true), ''),
                          'admin@nodex.local'));
  v_full_name  text := coalesce(
                          nullif(current_setting('nodex.bootstrap_admin_name', true), ''),
                          'Nodex Bootstrap Administrator');
  v_tenant_id  uuid := coalesce(
                          nullif(current_setting('nodex.bootstrap_tenant_id', true), ''),
                          '10000000-0000-4000-8000-000000000001')::uuid;
  v_role_key   text := coalesce(
                          nullif(current_setting('nodex.bootstrap_role_key', true), ''),
                          'hospital_super_admin');
  v_invite_id  uuid;
  v_user_id    uuid;
  v_invite     public.user_invites;
begin
  if v_password is null or length(v_password) < 12 then
    raise exception 'NODEX: set nodex.bootstrap_password to at least 12 characters before running this script'
      using errcode = '22023';
  end if;

  if not exists (select 1 from public.tenants t where t.id = v_tenant_id) then
    raise exception 'NODEX: tenant % does not exist; seed the bootstrap tenant first', v_tenant_id
      using errcode = '23503';
  end if;

  if not exists (select 1 from public.roles r where r.key = v_role_key) then
    raise exception 'NODEX: role % is not in the RBAC catalogue', v_role_key
      using errcode = '23503';
  end if;

  -- Invite first. Provisioning is an AFTER INSERT trigger on auth.users, so it
  -- can only grant what is already pending when the user row appears.
  select i.* into v_invite
  from public.user_invites i
  where i.tenant_id = v_tenant_id
    and lower(i.email) = v_email
    and i.role_key = v_role_key
  order by i.created_at desc
  limit 1;

  if v_invite.id is null then
    insert into public.user_invites (
      tenant_id, email, full_name, role_key, status, valid_until
    )
    values (
      v_tenant_id, v_email, v_full_name, v_role_key, 'pending', now() + interval '30 days'
    )
    returning id into v_invite_id;

    raise notice 'NODEX: created invite % for % (% in tenant %)',
      v_invite_id, v_email, v_role_key, v_tenant_id;
  else
    v_invite_id := v_invite.id;
    raise notice 'NODEX: invite % for % already exists with status %',
      v_invite_id, v_email, v_invite.status;
  end if;

  select u.id into v_user_id
  from auth.users u
  where lower(u.email) = v_email;

  if v_user_id is null then
    v_user_id := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
    )
    values (
      '00000000-0000-0000-0000-000000000000', v_user_id, 'authenticated', 'authenticated',
      v_email, extensions.crypt(v_password, extensions.gen_salt('bf')),
      now(), now(), now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      '{}'::jsonb, false, false
    );

    insert into auth.identities (
      provider_id, user_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    values (
      v_user_id::text, v_user_id,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email', now(), now(), now()
    );

    raise notice 'NODEX: created Auth user % for %', v_user_id, v_email;
  else
    update auth.users u
       set confirmation_token         = coalesce(u.confirmation_token, ''),
           recovery_token             = coalesce(u.recovery_token, ''),
           email_change               = coalesce(u.email_change, ''),
           email_change_token_new     = coalesce(u.email_change_token_new, ''),
           email_change_token_current = coalesce(u.email_change_token_current, ''),
           phone_change               = coalesce(u.phone_change, ''),
           phone_change_token         = coalesce(u.phone_change_token, ''),
           reauthentication_token     = coalesce(u.reauthentication_token, ''),
           email_confirmed_at         = coalesce(u.email_confirmed_at, now())
     where u.id = v_user_id;

    if not exists (
      select 1 from auth.identities i
      where i.user_id = v_user_id and i.provider = 'email'
    ) then
      insert into auth.identities (
        provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
      )
      values (
        v_user_id::text, v_user_id,
        jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
        'email', now(), now(), now()
      );
    end if;

  -- The grant itself is the trigger's job. If an Auth user somehow exists without
  -- one, the trigger already missed its window (it only fires on insert), so say
  -- so instead of fabricating an unaudited app_users row.
  if not exists (select 1 from public.app_users a where a.id = v_user_id) then
    raise exception 'NODEX: Auth user % has no app_users row and invite % is still %; the provisioning trigger fires on sign-up only. Delete the orphan Auth user and re-run this script.',
      v_user_id, v_invite_id,
      coalesce((select i.status from public.user_invites i where i.id = v_invite_id), 'missing')
      using errcode = '42501';
  end if;

  raise notice 'NODEX: bootstrap administrator ready - user %, invite %', v_user_id, v_invite_id;
end
$bootstrap$;

-- Verification: exactly one row, confirmed, active membership, invite accepted.
select u.id                             as user_id,
       u.email,
       u.email_confirmed_at is not null as confirmed,
       a.status                         as app_user_status,
       m.role_key,
       m.status                         as membership_status,
       m.tenant_id,
       i.status                         as invite_status
from auth.users u
left join public.app_users a   on a.id = u.id
left join public.memberships m on m.user_id = u.id
left join public.user_invites i on lower(i.email) = lower(u.email)
where lower(u.email) = lower(coalesce(
        nullif(current_setting('nodex.bootstrap_admin_email', true), ''),
        'admin@nodex.local'));
