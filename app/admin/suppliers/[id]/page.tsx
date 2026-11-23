'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { ArrowLeft, Building2, CalendarDays, Wallet } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { supabase } from '@/lib/supabase';
import type { Supplier } from '@/types';
import { useTranslation } from '@/hooks/use-translation';

type SupplierPurchaseItem = {
  id: string;
  product_name: string | null;
  quantity: number;
  total: number;
};

type SupplierPurchase = {
  id: string;
  po_number: string | null;
  purchase_date: string;
  total: number;
  paid_amount: number;
  due_amount: number;
  payment_status: string | null;
  status: string;
  purchase_items: SupplierPurchaseItem[] | null;
};

type SupplierPayment = {
  id: string;
  amount: number;
  payment_date: string;
  payment_method: string | null;
  note: string | null;
};

type SupplierReturnItem = {
  id: string;
  product_name: string | null;
  quantity: number;
  total: number;
};

type SupplierReturn = {
  id: string;
  po_number: string;
  original_purchase_id: string | null;
  return_date: string;
  total: number;
  status: string;
  reason: string | null;
  notes: string | null;
  purchase_return_items: SupplierReturnItem[] | null;
};

type ProfileTab = 'overview' | 'purchases' | 'payments' | 'returns';

type PageError = { message: string; code?: string };

async function fetchAllPages<T>(
  loadPage: (from: number, to: number) => Promise<{ data: T[] | null; error: PageError | null }>
): Promise<{ data: T[] | null; error: PageError | null }> {
  const pageSize = 1000;
  const rows: T[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await loadPage(from, from + pageSize - 1);
    if (error) return { data: null, error };
    const page = data || [];
    rows.push(...page);
    if (page.length < pageSize) return { data: rows, error: null };
  }
}

export default function SupplierProfilePage() {
  const params = useParams();
  const router = useRouter();
  const supplierId = params.id as string;
  const { t, locale } = useTranslation();
  const [supplier, setSupplier] = useState<Supplier | null>(null);
  const [purchases, setPurchases] = useState<SupplierPurchase[]>([]);
  const [payments, setPayments] = useState<SupplierPayment[]>([]);
  const [returns, setReturns] = useState<SupplierReturn[]>([]);
  const [activeTab, setActiveTab] = useState<ProfileTab>('overview');
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  const loadData = useCallback(async () => {
    setLoading(true);
    setNotFound(false);
    setLoadError(null);
    const [supplierResult, purchasesResult, paymentsResult, returnsResult] = await Promise.all([
      supabase.from('suppliers').select('*').eq('id', supplierId).single(),
      fetchAllPages<SupplierPurchase>(async (from, to) => {
        const { data, error } = await supabase
          .from('purchases')
          .select('id, po_number, purchase_date, total, paid_amount, due_amount, payment_status, status, purchase_items(id, product_name, quantity, total)')
          .eq('supplier_id', supplierId)
          .order('purchase_date', { ascending: false })
          .order('id', { ascending: true })
          .range(from, to);
        return { data: data as unknown as SupplierPurchase[] | null, error };
      }),
      fetchAllPages<SupplierPayment>(async (from, to) => {
        const { data, error } = await supabase
          .from('supplier_payments')
          .select('id, amount, payment_date, payment_method, note')
          .eq('supplier_id', supplierId)
          .order('payment_date', { ascending: false })
          .order('id', { ascending: true })
          .range(from, to);
        return { data: data as SupplierPayment[] | null, error };
      }),
      fetchAllPages<SupplierReturn>(async (from, to) => {
        const { data, error } = await supabase
          .from('purchase_returns')
          .select('id, po_number, original_purchase_id, return_date, total, status, reason, notes, purchase_return_items(id, product_name, quantity, total)')
          .eq('supplier_id', supplierId)
          .order('return_date', { ascending: false })
          .order('id', { ascending: true })
          .range(from, to);
        return { data: data as unknown as SupplierReturn[] | null, error };
      }),
    ]);

    if (supplierResult.error) {
      if (supplierResult.error.code === 'PGRST116') {
        setNotFound(true);
      } else {
        console.error('Could not load supplier profile', supplierResult.error);
        setLoadError(supplierResult.error.message);
      }
      setLoading(false);
      return;
    }

    const transactionError = purchasesResult.error || paymentsResult.error || returnsResult.error;
    if (transactionError) {
      console.error('Could not load supplier transactions', transactionError);
      setLoadError(transactionError.message);
      setLoading(false);
      return;
    }

    setSupplier(supplierResult.data as Supplier);
    setPurchases(purchasesResult.data || []);
    setPayments(paymentsResult.data || []);
    setReturns(returnsResult.data || []);
    setLoading(false);
  }, [supplierId]);

  useEffect(() => {
    void loadData();
  }, [loadData]);

  const money = useCallback((value: number) =>
    `৳${Number(value || 0).toLocaleString(locale === 'bn' ? 'bn-BD' : 'en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
  [locale]);

  const dateText = useCallback((value: string | null | undefined) => {
    if (!value) return '—';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '—' : date.toLocaleDateString(locale === 'bn' ? 'bn-BD' : 'en-US');
  }, [locale]);

  const activePurchases = useMemo(
    () => purchases.filter((purchase) => purchase.status !== 'cancelled'),
    [purchases]
  );
  const completedReturns = useMemo(
    () => returns.filter((returned) => returned.status === 'completed'),
    [returns]
  );
  const purchaseTotal = activePurchases.reduce((sum, purchase) => sum + Number(purchase.total || 0), 0);
  const purchasePaid = activePurchases.reduce((sum, purchase) => sum + Number(purchase.paid_amount || 0), 0);
  const purchaseDue = activePurchases.reduce((sum, purchase) => sum + Number(purchase.due_amount || 0), 0)
    + Number(supplier?.previous_due || 0);
  const paymentTotal = payments.reduce((sum, payment) => sum + Number(payment.amount || 0), 0);
  const totalPaid = purchasePaid + paymentTotal;
  const returnTotal = completedReturns.reduce((sum, returned) => sum + Number(returned.total || 0), 0);
  const netBalance = purchaseDue - paymentTotal;
  const currentOutstanding = Math.max(0, netBalance);
  const supplierCredit = Math.max(0, -netBalance);
  const purchaseInvoiceById = useMemo(
    () => new Map(purchases.map((purchase) => [purchase.id, purchase.po_number || '—'])),
    [purchases]
  );
  const fullAddress = [supplier?.address, supplier?.city, supplier?.country].filter(Boolean).join(', ');

  const profileTabs: Array<{ id: ProfileTab; label: string }> = [
    { id: 'overview', label: t('suppliers.profile.overview') },
    { id: 'purchases', label: t('suppliers.profile.purchaseHistory') },
    { id: 'payments', label: t('suppliers.profile.paymentHistory') },
    { id: 'returns', label: t('suppliers.profile.returns') },
  ];

  if (loading) {
    return <div className="flex h-64 items-center justify-center text-muted-foreground">{t('suppliers.profile.loading')}</div>;
  }

  if (notFound) {
    return (
      <div className="space-y-4 py-16 text-center">
        <p className="text-muted-foreground">{t('suppliers.profile.notFound')}</p>
        <Button onClick={() => router.push('/admin/suppliers')}>{t('suppliers.profile.back')}</Button>
      </div>
    );
  }

  if (loadError || !supplier) {
    return (
      <Card className="space-y-4 p-6 text-center">
        <p className="text-sm text-destructive">{t('suppliers.profile.loadFailed')}{loadError ? `: ${loadError}` : ''}</p>
        <div className="flex justify-center gap-2">
          <Button variant="outline" onClick={() => router.push('/admin/suppliers')}>{t('suppliers.profile.back')}</Button>
          <Button onClick={() => void loadData()}>{t('suppliers.profile.retry')}</Button>
        </div>
      </Card>
    );
  }

  const details = [
    { label: t('suppliers.companyName'), value: supplier.company_name },
    { label: t('suppliers.contactPerson'), value: supplier.contact_person },
    { label: t('common.phone'), value: supplier.phone },
    { label: t('suppliers.alternatePhone'), value: supplier.alt_phone },
    { label: t('common.email'), value: supplier.email },
    { label: t('suppliers.address'), value: fullAddress },
    { label: t('suppliers.fatherName'), value: supplier.father_name },
    { label: t('suppliers.nidNumber'), value: supplier.nid_number },
    { label: t('suppliers.dateOfBirth'), value: supplier.date_of_birth ? dateText(supplier.date_of_birth) : null },
    { label: t('suppliers.bankAccount'), value: supplier.bank_account },
    { label: t('suppliers.alternateBankAccount'), value: supplier.alt_bank_account },
    { label: t('suppliers.referralNote'), value: supplier.referral_note },
    { label: t('suppliers.note'), value: supplier.note },
    { label: t('suppliers.imageUrl'), value: supplier.image_url },
    { label: t('suppliers.balance'), value: money(Number(supplier.balance || 0)) },
    { label: t('suppliers.profile.status'), value: t(supplier.status === 'active' ? 'common.active' : 'common.inactive') },
  ].filter((detail) => Boolean(detail.value));

  const formatPaymentStatus = (purchase: SupplierPurchase) =>
    purchase.payment_status || (Number(purchase.due_amount || 0) > 0 ? 'due' : 'paid');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <Button variant="outline" size="icon" aria-label={t('suppliers.profile.back')} onClick={() => router.push('/admin/suppliers')}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div className="min-w-0">
            <h2 className="break-words text-2xl font-bold font-heading">{supplier.name}</h2>
            <p className="text-sm text-muted-foreground">{t('suppliers.profile.subtitle')}</p>
          </div>
        </div>
        <Badge variant="secondary" className={supplier.status === 'active' ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400' : ''}>
          {t(supplier.status === 'active' ? 'common.active' : 'common.inactive')}
        </Badge>
      </div>

      <div className="flex gap-2 overflow-x-auto border-b pb-2" role="tablist" aria-label={t('suppliers.profile.supplierInformation')}>
        {profileTabs.map((tab) => (
          <Button
            key={tab.id}
            role="tab"
            aria-selected={activeTab === tab.id}
            variant={activeTab === tab.id ? 'default' : 'ghost'}
            size="sm"
            className="shrink-0"
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.label}
          </Button>
        ))}
      </div>

      {activeTab === 'overview' && (
        <div className="space-y-4">
          <Card className="space-y-4 p-5">
            <div className="flex items-center gap-3">
              <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-slate-800 to-black text-xl font-bold text-white">
                {supplier.name.charAt(0).toUpperCase()}
              </div>
              <div className="min-w-0">
                <h3 className="break-words text-lg font-semibold">{supplier.name}</h3>
                {supplier.company_name && <p className="flex items-center gap-1 text-sm text-muted-foreground"><Building2 className="h-4 w-4" />{supplier.company_name}</p>}
              </div>
            </div>
            <div className="grid gap-3 border-t pt-4 text-sm sm:grid-cols-2 lg:grid-cols-3">
              {details.length === 0 ? (
                <p className="text-muted-foreground">{t('suppliers.profile.noDetails')}</p>
              ) : details.map((detail) => (
                <div key={detail.label} className="min-w-0">
                  <p className="text-xs text-muted-foreground">{detail.label}</p>
                  <p className="break-words font-medium">{detail.value}</p>
                </div>
              ))}
              {supplier.created_at && (
                <div>
                  <p className="text-xs text-muted-foreground">{t('suppliers.profile.createdAt')}</p>
                  <p className="flex items-center gap-1 font-medium"><CalendarDays className="h-4 w-4 text-muted-foreground" />{dateText(supplier.created_at)}</p>
                </div>
              )}
            </div>
          </Card>

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {[
              { label: t('suppliers.totalPurchases'), value: money(purchaseTotal) },
              { label: t('suppliers.totalPaid'), value: money(totalPaid) },
              { label: t('suppliers.totalDue'), value: money(purchaseDue) },
              { label: t('suppliers.totalReturned'), value: money(returnTotal) },
              { label: t('suppliers.currentOutstanding'), value: money(currentOutstanding) },
              ...(supplierCredit > 0 ? [{ label: t('suppliers.creditBalance'), value: money(supplierCredit) }] : []),
              { label: t('suppliers.profile.lastPurchase'), value: activePurchases[0] ? dateText(activePurchases[0].purchase_date) : '—' },
            ].map((stat) => (
              <Card key={stat.label} className="p-4">
                <p className="text-xs text-muted-foreground">{stat.label}</p>
                <p className="mt-1 break-words font-bold">{stat.value}</p>
              </Card>
            ))}
          </div>
          <Card className="flex items-center gap-2 p-4 text-sm text-muted-foreground">
            <Wallet className="h-4 w-4 shrink-0" />
            <span>{t('suppliers.profile.balanceNote')}</span>
          </Card>
        </div>
      )}

      {activeTab === 'purchases' && (
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <Table className="min-w-[900px]">
              <TableHeader><TableRow>
                <TableHead>{t('suppliers.profile.purchaseInvoice')}</TableHead>
                <TableHead>{t('suppliers.profile.date')}</TableHead>
                <TableHead>{t('suppliers.profile.items')}</TableHead>
                <TableHead>{t('suppliers.profile.amount')}</TableHead>
                <TableHead>{t('suppliers.profile.paid')}</TableHead>
                <TableHead>{t('suppliers.profile.due')}</TableHead>
                <TableHead>{t('suppliers.profile.paymentStatus')}</TableHead>
                <TableHead>{t('suppliers.profile.status')}</TableHead>
              </TableRow></TableHeader>
              <TableBody>
                {purchases.length === 0 ? (
                  <TableRow><TableCell colSpan={8} className="py-8 text-center text-muted-foreground">{t('suppliers.profile.noPurchases')}</TableCell></TableRow>
                ) : purchases.map((purchase) => (
                  <TableRow key={purchase.id}>
                    <TableCell className="font-medium">{purchase.po_number || '—'}</TableCell>
                    <TableCell className="whitespace-nowrap">{dateText(purchase.purchase_date)}</TableCell>
                    <TableCell className="max-w-[260px] whitespace-normal">
                      {(purchase.purchase_items || []).map((item) => `${item.product_name || '—'} × ${item.quantity}`).join(', ') || '—'}
                    </TableCell>
                    <TableCell className="font-medium">{money(Number(purchase.total || 0))}</TableCell>
                    <TableCell className="text-emerald-600">{money(Number(purchase.paid_amount || 0))}</TableCell>
                    <TableCell className={Number(purchase.due_amount || 0) > 0 ? 'text-amber-600' : 'text-muted-foreground'}>{money(Number(purchase.due_amount || 0))}</TableCell>
                    <TableCell><Badge variant="outline" className="capitalize">{formatPaymentStatus(purchase)}</Badge></TableCell>
                    <TableCell><Badge variant={purchase.status === 'cancelled' ? 'destructive' : 'secondary'} className="capitalize">{purchase.status}</Badge></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}

      {activeTab === 'payments' && (
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <Table className="min-w-[650px]">
              <TableHeader><TableRow>
                <TableHead>{t('suppliers.profile.date')}</TableHead>
                <TableHead>{t('suppliers.profile.amount')}</TableHead>
                <TableHead>{t('suppliers.profile.method')}</TableHead>
                <TableHead>{t('suppliers.profile.reference')}</TableHead>
              </TableRow></TableHeader>
              <TableBody>
                {payments.length === 0 ? (
                  <TableRow><TableCell colSpan={4} className="py-8 text-center text-muted-foreground">{t('suppliers.profile.noPayments')}</TableCell></TableRow>
                ) : payments.map((payment) => (
                  <TableRow key={payment.id}>
                    <TableCell className="whitespace-nowrap">{dateText(payment.payment_date)}</TableCell>
                    <TableCell className="font-medium text-emerald-600">{money(Number(payment.amount || 0))}</TableCell>
                    <TableCell className="capitalize">{payment.payment_method || '—'}</TableCell>
                    <TableCell className="max-w-[320px] whitespace-normal">{payment.note || '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}

      {activeTab === 'returns' && (
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <Table className="min-w-[800px]">
              <TableHeader><TableRow>
                <TableHead>{t('suppliers.profile.returnInvoice')}</TableHead>
                <TableHead>{t('suppliers.profile.originalInvoice')}</TableHead>
                <TableHead>{t('suppliers.profile.date')}</TableHead>
                <TableHead>{t('suppliers.profile.items')}</TableHead>
                <TableHead>{t('suppliers.profile.amount')}</TableHead>
                <TableHead>{t('suppliers.profile.reason')}</TableHead>
                <TableHead>{t('suppliers.profile.status')}</TableHead>
              </TableRow></TableHeader>
              <TableBody>
                {returns.length === 0 ? (
                  <TableRow><TableCell colSpan={7} className="py-8 text-center text-muted-foreground">{t('suppliers.profile.noReturns')}</TableCell></TableRow>
                ) : returns.map((returned) => (
                  <TableRow key={returned.id}>
                    <TableCell className="font-medium">{returned.po_number || '—'}</TableCell>
                    <TableCell>{returned.original_purchase_id ? purchaseInvoiceById.get(returned.original_purchase_id) || '—' : '—'}</TableCell>
                    <TableCell className="whitespace-nowrap">{dateText(returned.return_date)}</TableCell>
                    <TableCell className="max-w-[280px] whitespace-normal">
                      {(returned.purchase_return_items || []).map((item) => `${item.product_name || '—'} × ${item.quantity}`).join(', ') || '—'}
                    </TableCell>
                    <TableCell className="font-medium">{money(Number(returned.total || 0))}</TableCell>
                    <TableCell className="max-w-[220px] whitespace-normal">{returned.reason || returned.notes || '—'}</TableCell>
                    <TableCell><Badge variant={returned.status === 'completed' ? 'default' : 'secondary'} className="capitalize">{returned.status}</Badge></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}
    </div>
  );
}
