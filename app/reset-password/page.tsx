'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { supabase } from '@/lib/supabase';
import { toast } from 'sonner';

export default function ResetPasswordPage() {
  const router = useRouter();
  const [checkingSession, setCheckingSession] = useState(true);
  const [hasRecoverySession, setHasRecoverySession] = useState(false);
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let active = true;
    void supabase.auth.getSession().then(({ data, error }) => {
      if (!active) return;
      if (error) toast.error(error.message);
      setHasRecoverySession(Boolean(data.session));
      setCheckingSession(false);
    }).catch((error: unknown) => {
      if (!active) return;
      toast.error(error instanceof Error ? error.message : 'Unable to verify the password reset session.');
      setCheckingSession(false);
    });
    return () => { active = false; };
  }, []);

  const updatePassword = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (password.length < 8) {
      toast.error('Use a password with at least 8 characters.');
      return;
    }
    if (password !== confirmPassword) {
      toast.error('The passwords do not match.');
      return;
    }
    setSaving(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      const { error: signOutError } = await supabase.auth.signOut({ scope: 'global' });
      if (signOutError) throw signOutError;
      toast.success('Password updated. Sign in using your new password.');
      router.replace('/login');
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Unable to update the password.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/30 p-6">
      <Card className="w-full max-w-md space-y-5 p-6">
        <div>
          <h1 className="text-2xl font-bold">Reset your password</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Choose a new password for your Nirvul POS account.
          </p>
        </div>
        {checkingSession ? <p role="status" className="text-sm text-muted-foreground">Verifying reset link...</p> :
          !hasRecoverySession ? (
            <div className="space-y-3">
              <p role="alert" className="text-sm text-destructive">This password reset link is invalid or expired.</p>
              <Button asChild variant="outline"><Link href="/login">Return to sign in</Link></Button>
            </div>
          ) : (
            <form onSubmit={updatePassword} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="new-password">New password</Label>
                <Input id="new-password" type="password" autoComplete="new-password" minLength={8}
                  required value={password} onChange={(event) => setPassword(event.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="confirm-password">Confirm password</Label>
                <Input id="confirm-password" type="password" autoComplete="new-password" minLength={8}
                  required value={confirmPassword} onChange={(event) => setConfirmPassword(event.target.value)} />
              </div>
              <Button type="submit" className="w-full" disabled={saving}>
                {saving ? 'Updating...' : 'Update password'}
              </Button>
            </form>
          )}
      </Card>
    </main>
  );
}
