# Supabase Staging Rehearsal Checklist

This checklist is a preparation aid, not authorization to modify production.
Do not use production credentials or run the rehearsal against production.

## Before rehearsal

- [ ] Confirm the exact staging project ref and verify it is disposable.
- [ ] Confirm the production project ref and environment independently.
- [ ] Take and verify a restorable backup of the staging data.
- [ ] Reconcile the complete local and remote migration lists. Obtain the actual
      SQL source for every remote-only version; do not hide gaps with migration
      history repair.
- [ ] Review each migration in order, including its prerequisites, data impact,
      locks, grants, RLS policies, Auth triggers, and rollback/recovery path.
- [ ] Complete `ownership_mapping_template.csv` from authorized evidence.
      Leave ambiguous rows unmapped. Record the owner's decision and evidence.
- [ ] Explicitly decide how duplicate units are handled and which unit, if any,
      represents each legacy product unit value such as `pcs`.
- [ ] Stop if a migration contains an unapproved hard-coded owner, blanket
      backfill, destructive policy replacement, or assumption about existing
      rows.

## Rehearse on staging

- [ ] Apply only the reviewed migration sequence to the disposable staging
      project, in a recorded order.
- [ ] Confirm the migration command reports success and the remote ledger
      matches the reviewed migration set.
- [ ] Compare before/after row counts and verify no unmapped records were
      reassigned, deleted, or made inaccessible unexpectedly.
- [ ] Test RLS and grants as `anon`, `authenticated`, each supported store role,
      and Super Admin; verify cross-store reads and writes are denied except
      for explicitly approved operations.
- [ ] Test signup, approval, employee invitation, POS checkout, inventory
      changes, returns, and reports affected by the migration set.
- [ ] Verify `store_id` and unit references, constraints, indexes, triggers,
      and function privileges against the approved design.
- [ ] Exercise the documented restore/recovery procedure or verify that the
      backup can be restored to a separate disposable project.
- [ ] Record the staging ref, migration versions, test results, failures, and
      reviewer sign-off. Fix and repeat any failed case.

## Production release gate

- [ ] Obtain explicit production-write approval for the exact project ref and
      reviewed migration versions.
- [ ] Confirm a fresh restorable production backup and recovery owner.
- [ ] Confirm the production migration list still matches the reviewed
      baseline; stop if it changed.
- [ ] Schedule the approved release window and monitor each migration.
- [ ] Verify the production ledger, schema, RLS, and key application flows after
      deployment; record the result.

Never use `db reset` on production. A successful staging rehearsal alone does
not authorize a production write.
