'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowDown, ArrowUp, Download, Loader2, Printer } from 'lucide-react';
import { toast } from 'sonner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useConfirmation } from '@/hooks/use-confirmation';
import { useTranslation } from '@/hooks/use-translation';
import { supabase } from '@/lib/supabase';
import { escapeCsvCell } from '@/lib/safe-export';

type AdjustmentType = 'increase' | 'decrease' | 'set_actual';
type DatePreset = 'today' | 'yesterday' | 'last7' | 'last30' | 'month' | 'custom';

type ProductOption = {
  id: string;
  name: string;
  sku: string | null;
  barcode: string | null;
  unit: string | null;
  stock: number;
};

type AdjustmentRow = {
  id: string;
  adjusted_at: string;
  product_id: string;
  product_name: string;
  sku: string | null;
  barcode: string | null;
  previous_quantity: number;
  adjustment_type: AdjustmentType;
  quantity: number;
  new_quantity: number;
  difference: number;
  unit: string | null;
  reason: string;
  reason_details: string | null;
  notes: string | null;
  adjusted_by_user_id: string | null;
  adjusted_by: string | null;
  value_impact: number | null;
  total_count: number;
};

type Report = {
  total_adjustments: number;
  total_increased: number;
  total_decreased: number;
  total_value_impact: number | null;
  by_product: Array<{ product_id: string; product_name: string; sku: string | null; count: number }>;
  by_employee: Array<{ user_id: string | null; name: string | null; count: number }>;
  by_reason: Array<{ reason: string; count: number }>;
};

const REASONS = [
  'physical_stock_correction',
  'damaged_products',
  'expired_products',
  'lost_missing_products',
  'found_extra_stock',
  'opening_stock_correction',
  'internal_stock_correction',
  'other',
] as const;

const PAGE_SIZE = 25;

function isDecimalUnit(unit: string | null): boolean {
  return /^(kg|g|gram|grams|liter|litre|l|ml|meter|metre|m|cm|mm)$/i.test((unit || '').trim());
}

function dateBounds(preset: DatePreset, customFrom: string, customTo: string): { from: string; to: string } {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const end = new Date(start);
  end.setDate(end.getDate() + 1);

  if (preset === 'yesterday') {
    start.setDate(start.getDate() - 1);
    end.setDate(end.getDate() - 1);
  } else if (preset === 'last7') {
    start.setDate(start.getDate() - 6);
  } else if (preset === 'last30') {
    start.setDate(start.getDate() - 29);
  } else if (preset === 'month') {
    start.setDate(1);
  } else if (preset === 'custom') {
    const parseDate = (value: string) => {
      if (!value) return null;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('Invalid custom stock-adjustment date.');
      const [year, month, day] = value.split('-').map(Number);
      const date = new Date(year, month - 1, day);
      if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) {
        throw new Error('Invalid custom stock-adjustment date.');
      }
      return date;
    };
    const customStart = parseDate(customFrom);
    const customEnd = parseDate(customTo);
    if (customStart && customEnd && customStart > customEnd) {
      throw new Error('The custom stock-adjustment start date must not be after its end date.');
    }
    if (customEnd) customEnd.setDate(customEnd.getDate() + 1);
    return {
      from: customStart?.toISOString() || '',
      to: customEnd?.toISOString() || '',
    };
  }
  return { from: start.toISOString(), to: end.toISOString() };
}

function logStockAdjustmentError(context: string, error: unknown) {
  const details = typeof error === 'object' && error !== null
    ? error as Record<string, unknown>
    : null;
  if (details && ['code', 'details', 'hint'].some((key) => key in details)) {
    const diagnostic = {
      kind: 'supabase',
      message: typeof details.message === 'string' ? details.message : undefined,
      code: typeof details.code === 'string' ? details.code : undefined,
      details: typeof details.details === 'string' ? details.details : undefined,
      hint: typeof details.hint === 'string' ? details.hint : undefined,
    };
    console.error(`[Stock adjustments] ${context} ${JSON.stringify(diagnostic)}`);
    return;
  }
  if (error instanceof Error) {
    const diagnostic = {
      kind: 'javascript',
      name: error.name,
      message: error.message,
      stack: error.stack,
    };
    console.error(`[Stock adjustments] ${context} ${JSON.stringify(diagnostic)}`);
    return;
  }
  const diagnostic = {
    kind: 'unknown',
    name: details && typeof details.name === 'string' ? details.name : undefined,
    message: details && typeof details.message === 'string'
      ? details.message
      : typeof error === 'string' ? error : undefined,
    stack: details && typeof details.stack === 'string' ? details.stack : undefined,
    valueType: error === null ? 'null' : typeof error,
  };
  console.error(`[Stock adjustments] ${context} ${JSON.stringify(diagnostic)}`);
}

function getHistoryLoadError(error: unknown, rpcName: string, t: (key: string) => string) {
  const details = typeof error === 'object' && error !== null
    ? error as { code?: unknown; message?: unknown }
    : null;
  if (
    details?.code === 'PGRST202' ||
    (typeof details?.message === 'string' && details.message.includes(rpcName))
  ) {
    return t('stockAdjustments.migrationRequired');
  }
  if (details?.code === '42501') return t('stockAdjustments.historyPermissionDenied');
  return t('stockAdjustments.loadFailed');
}

export default function AdjustmentManager({ onAdjusted }: { onAdjusted: () => Promise<void> }) {
  const { t, locale } = useTranslation();
  const { confirmAction, dialog: confirmationDialog } = useConfirmation();
  const [products, setProducts] = useState<ProductOption[]>([]);
  const [permissions, setPermissions] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const idempotencyKeyRef = useRef<{ signature: string; key: string } | null>(null);
  const [productId, setProductId] = useState('');
  const [adjustmentType, setAdjustmentType] = useState<AdjustmentType>('increase');
  const [quantity, setQuantity] = useState('');
  const [reason, setReason] = useState<string>(REASONS[0]);
  const [reasonDetails, setReasonDetails] = useState('');
  const [notes, setNotes] = useState('');
  const [unitCost, setUnitCost] = useState('');
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState('all');
  const [reasonFilter, setReasonFilter] = useState('all');
  const [employeeFilter, setEmployeeFilter] = useState('all');
  const [preset, setPreset] = useState<DatePreset>('last7');
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<AdjustmentRow[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [report, setReport] = useState<Report | null>(null);
  const [historyLoading, setHistoryLoading] = useState(true);
  const [reportLoading, setReportLoading] = useState(true);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [reportError, setReportError] = useState<string | null>(null);
  const historyRequestId = useRef(0);

  const permissionSet = useMemo(() => new Set(permissions), [permissions]);
  const isOwner = permissionSet.has('*');
  const canView = isOwner || permissionSet.has('stock_reconciliation.view') || permissionSet.has('inventory.view');
  const canIncrease = isOwner || permissionSet.has('actions.adjust_stock_increase');
  const canDecrease = isOwner || permissionSet.has('actions.adjust_stock_decrease');
  const canSetActual = isOwner || permissionSet.has('stock_reconciliation.edit');
  const canViewValue = isOwner || permissionSet.has('actions.view_stock_value');
  const canSetUnitCost = isOwner || permissionSet.has('actions.view_purchase_price');
  const canExport = isOwner || permissionSet.has('stock_reconciliation.export');
  const canPrint = isOwner || permissionSet.has('stock_reconciliation.print');

  const selectedProduct = products.find((product) => product.id === productId) || null;
  const enteredQuantity = Number(quantity);
  const calculatedStock = selectedProduct && Number.isFinite(enteredQuantity)
    ? adjustmentType === 'increase'
      ? selectedProduct.stock + enteredQuantity
      : adjustmentType === 'decrease'
        ? selectedProduct.stock - enteredQuantity
        : enteredQuantity
    : null;

  const loadPermissionsAndProducts = useCallback(async () => {
    const [permissionResult, productResult] = await Promise.all([
      supabase.rpc('get_my_permissions'),
      supabase.from('products')
        .select('id, name, sku, barcode, unit, stock')
        .eq('is_deleted', false)
        .eq('status', 'active')
        .order('name'),
    ]);
    if (permissionResult.error) throw permissionResult.error;
    if (productResult.error) throw productResult.error;
    setPermissions(permissionResult.data || []);
    setProducts((productResult.data || []).map((product) => ({
      ...product,
      stock: Number(product.stock || 0),
    })));
    setLoading(false);
  }, []);

  useEffect(() => {
    const timeoutId = window.setTimeout(() => setDebouncedSearch(search.trim()), 300);
    return () => window.clearTimeout(timeoutId);
  }, [search]);

  const loadHistoryAndReport = useCallback(async () => {
    if (!canView) return;
    const requestId = ++historyRequestId.current;
    setHistoryLoading(true);
    setReportLoading(true);
    setHistoryError(null);
    setReportError(null);
    try {
      const bounds = dateBounds(preset, customFrom, customTo);
      const from = bounds.from || null;
      const to = bounds.to || null;
      const [historyResult, reportResult] = await Promise.all([
        supabase.rpc('get_stock_adjustment_history', {
          p_from: from,
          p_to: to,
          p_adjustment_type: typeFilter === 'all' ? null : typeFilter,
          p_employee_id: employeeFilter === 'all' ? null : employeeFilter,
          p_reason: reasonFilter === 'all' ? null : reasonFilter,
          p_search: debouncedSearch || null,
          p_offset: page * PAGE_SIZE,
          p_limit: PAGE_SIZE,
        }),
        supabase.rpc('get_stock_adjustment_report', { p_from: from, p_to: to }),
      ]);
      if (requestId !== historyRequestId.current) return;

      if (historyResult.error) {
        logStockAdjustmentError('History RPC failed:', historyResult.error);
        setRows([]);
        setTotalCount(0);
        const message = getHistoryLoadError(historyResult.error, 'get_stock_adjustment_history', t);
        setHistoryError(message);
        toast.error(message);
      } else {
        const pageRows = (historyResult.data || []) as AdjustmentRow[];
        setRows(pageRows);
        setTotalCount(Number(pageRows[0]?.total_count || 0));
      }

      if (reportResult.error) {
        logStockAdjustmentError('Report RPC failed:', reportResult.error);
        setReport(null);
        const message = getHistoryLoadError(reportResult.error, 'get_stock_adjustment_report', t);
        setReportError(message);
        toast.error(message);
      } else {
        setReport((reportResult.data as Report | null) || null);
      }
    } catch (error) {
      if (requestId !== historyRequestId.current) return;
      logStockAdjustmentError('History and report request failed:', error);
      setRows([]);
      setTotalCount(0);
      setReport(null);
      setHistoryError(t('stockAdjustments.loadFailed'));
      setReportError(t('stockAdjustments.reportLoadFailed'));
      toast.error(t('stockAdjustments.loadFailed'));
    } finally {
      if (requestId === historyRequestId.current) {
        setHistoryLoading(false);
        setReportLoading(false);
      }
    }
  }, [canView, customFrom, customTo, debouncedSearch, employeeFilter, page, preset, reasonFilter, t, typeFilter]);

  useEffect(() => {
    let active = true;
    void loadPermissionsAndProducts()
      .catch((error) => {
        if (active) {
          console.error('[Stock adjustments] Failed to load access and products:', error);
          toast.error(t('stockAdjustments.loadFailed'));
          setLoading(false);
        }
      });
    const refreshPermissions = () => {
      if (document.visibilityState === 'visible') {
        void loadPermissionsAndProducts().catch((error) => {
          console.error('[Stock adjustments] Failed to refresh access:', error);
        });
      }
    };
    const refreshTimer = window.setInterval(refreshPermissions, 15000);
    window.addEventListener('focus', refreshPermissions);
    return () => {
      active = false;
      window.clearInterval(refreshTimer);
      window.removeEventListener('focus', refreshPermissions);
    };
  }, [loadPermissionsAndProducts, t]);

  useEffect(() => {
    void loadHistoryAndReport();
    return () => { historyRequestId.current += 1; };
  }, [loadHistoryAndReport, t]);

  const handleAdjustment = async () => {
    if (!selectedProduct || !quantity.trim() || !Number.isFinite(enteredQuantity) || enteredQuantity < 0) {
      toast.error(t('stockAdjustments.invalidQuantity'));
      return;
    }
    if (adjustmentType !== 'set_actual' && enteredQuantity === 0) {
      toast.error(t('stockAdjustments.invalidQuantity'));
      return;
    }
    if (!isDecimalUnit(selectedProduct.unit) && !Number.isInteger(enteredQuantity)) {
      toast.error(t('stockAdjustments.wholeQuantityOnly'));
      return;
    }
    if (calculatedStock === null || calculatedStock < 0) {
      toast.error(t('stockAdjustments.insufficientStock'));
      return;
    }
    if ((calculatedStock > selectedProduct.stock && !canIncrease)
      || (calculatedStock < selectedProduct.stock && !canDecrease)) {
      toast.error(t('stockAdjustments.noPermission'));
      return;
    }
    if (reason === 'other' && !reasonDetails.trim()) {
      toast.error(t('stockAdjustments.customReasonRequired'));
      return;
    }
    const cost = unitCost.trim() ? Number(unitCost) : null;
    if (unitCost.trim() && (!Number.isFinite(cost) || Number(cost) < 0)) {
      toast.error(t('stockAdjustments.invalidCost'));
      return;
    }

    await confirmAction({
      title: t('stockAdjustments.confirmTitle'),
      description: t('stockAdjustments.confirmDescription', {
        product: selectedProduct.name,
        previous: String(selectedProduct.stock),
        next: String(calculatedStock),
        unit: selectedProduct.unit || '',
      }),
      confirmLabel: t('stockAdjustments.save'),
      destructive: adjustmentType === 'decrease' || (calculatedStock < selectedProduct.stock),
      successMessage: t('stockAdjustments.success'),
      action: async () => {
        setSaving(true);
        try {
          const signature = JSON.stringify([
            productId, adjustmentType, enteredQuantity, reason, reasonDetails, notes, cost,
            selectedProduct.stock,
          ]);
          if (idempotencyKeyRef.current?.signature !== signature) {
            idempotencyKeyRef.current = { signature, key: crypto.randomUUID() };
          }
          const { error } = await supabase.rpc('perform_stock_adjustment', {
            p_product_id: productId,
            p_adjustment_type: adjustmentType,
            p_quantity: enteredQuantity,
            p_reason: reason,
            p_reason_details: reason === 'other' ? reasonDetails.trim() : null,
            p_notes: notes.trim() || null,
            p_expected_current_stock: selectedProduct.stock,
            p_idempotency_key: idempotencyKeyRef.current.key,
            p_reconciliation_id: null,
            p_unit_cost: adjustmentType === 'increase' ? cost : null,
          });
          if (error) throw error;
          setQuantity('');
          setReasonDetails('');
          setNotes('');
          setUnitCost('');
          idempotencyKeyRef.current = null;
          await Promise.all([onAdjusted(), loadPermissionsAndProducts(), loadHistoryAndReport()]);
        } finally {
          setSaving(false);
        }
      },
    });
  };

  const exportCsv = async () => {
    const bounds = dateBounds(preset, customFrom, customTo);
    const from = bounds.from || null;
    const to = bounds.to || null;
    const exported: AdjustmentRow[] = [];
    for (let offset = 0; offset < totalCount; offset += 500) {
      const { data, error } = await supabase.rpc('get_stock_adjustment_export', {
        p_from: from,
        p_to: to,
        p_adjustment_type: typeFilter === 'all' ? null : typeFilter,
        p_employee_id: employeeFilter === 'all' ? null : employeeFilter,
        p_reason: reasonFilter === 'all' ? null : reasonFilter,
        p_search: search.trim() || null,
        p_offset: offset,
        p_limit: 500,
      });
      if (error) {
        toast.error(t('stockAdjustments.exportFailed'));
        return;
      }
      const next = (data || []) as AdjustmentRow[];
      exported.push(...next);
      if (next.length < 500) break;
    }
    const headers = [
      t('stockAdjustments.id'), t('stockAdjustments.date'), t('stockAdjustments.product'),
      t('stockAdjustments.sku'), t('stockAdjustments.previous'), t('stockAdjustments.type'),
      t('stockAdjustments.quantity'), t('stockAdjustments.new'), t('stockAdjustments.reason'),
      t('stockAdjustments.adjustedBy'), t('stockAdjustments.notes'),
    ];
    const csvRows = exported.map((row) => [
      row.id, row.adjusted_at, row.product_name, row.sku || '', String(row.previous_quantity),
      t(`stockAdjustments.types.${row.adjustment_type}`), String(row.quantity),
      String(row.new_quantity), t(`stockAdjustments.reasons.${row.reason}`),
      row.adjusted_by || '', row.notes || '',
    ]);
    const blob = new Blob(
      ['\ufeff', [headers, ...csvRows].map((line) => line.map(escapeCsvCell).join(',')).join('\r\n')],
      { type: 'text/csv;charset=utf-8' }
    );
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `stock-adjustments-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  };

  const pageCount = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));
  const employees = report?.by_employee || [];
  const summaryCards: { label: string; value: string | number; className: string }[] = [
    { label: t('stockAdjustments.totalAdjustments'), value: report?.total_adjustments ?? 0, className: '' },
    { label: t('stockAdjustments.totalIncreased'), value: report?.total_increased ?? 0, className: 'text-emerald-600' },
    { label: t('stockAdjustments.totalDecreased'), value: report?.total_decreased ?? 0, className: 'text-rose-600' },
    { label: t('stockAdjustments.valueImpact'), value: canViewValue ? report?.total_value_impact ?? '—' : '—', className: '' },
  ];
  const reportGroups = report ? [
    {
      title: t('stockAdjustments.byProduct'),
      entries: report.by_product.map((entry) => ({ id: entry.product_id, label: entry.product_name, count: entry.count })),
    },
    {
      title: t('stockAdjustments.byEmployee'),
      entries: report.by_employee.map((entry) => ({ id: entry.user_id || entry.name || '', label: entry.name || entry.user_id || '', count: entry.count })),
    },
    {
      title: t('stockAdjustments.byReason'),
      entries: report.by_reason.map((entry) => ({ id: entry.reason, label: t(`stockAdjustments.reasons.${entry.reason}`), count: entry.count })),
    },
  ] : [];

  return (
    <div className="space-y-5">
      {confirmationDialog}
      <div>
        <h3 className="text-xl font-semibold">{t('stockAdjustments.title')}</h3>
        <p className="text-sm text-muted-foreground">{t('stockAdjustments.subtitle')}</p>
      </div>

      {loading ? (
        <Card className="flex items-center justify-center gap-2 p-8 text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" /> {t('common.loading')}
        </Card>
      ) : !canView ? (
        <Card className="p-5 text-sm text-muted-foreground">{t('stockAdjustments.noPermission')}</Card>
      ) : (
        <>
          {(historyError || reportError) && (
            <div role="alert" className="space-y-2 rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm">
              {historyError && <p>{historyError}</p>}
              {reportError && <p>{reportError}</p>}
              <Button size="sm" variant="outline" onClick={() => void loadHistoryAndReport()}
                disabled={historyLoading || reportLoading}>
                {t('stockAdjustments.retry')}
              </Button>
            </div>
          )}
          {reportLoading && (
            <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" /> {t('stockAdjustments.refreshingReport')}
            </p>
          )}

          {(canIncrease || canDecrease || canSetActual) && (
            <Card className="space-y-4 p-4">
              <div className="flex items-center gap-2">
                <h4 className="font-semibold">{t('stockAdjustments.newAdjustment')}</h4>
                <Badge variant="outline">{t('stockAdjustments.serverValidated')}</Badge>
              </div>
              <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
                <div className="space-y-1">
                  <Label>{t('stockAdjustments.product')}</Label>
                  <Select value={productId} onValueChange={(value) => {
                    setProductId(value);
                    setQuantity('');
                  }}>
                    <SelectTrigger><SelectValue placeholder={t('stockAdjustments.selectProduct')} /></SelectTrigger>
                    <SelectContent>
                      {products.map((product) => (
                        <SelectItem key={product.id} value={product.id}>
                          {product.name} ({product.stock} {product.unit || ''})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label>{t('stockAdjustments.type')}</Label>
                  <Select value={adjustmentType} onValueChange={(value) => {
                    setAdjustmentType(value as AdjustmentType);
                    setQuantity('');
                  }}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {canIncrease && <SelectItem value="increase">{t('stockAdjustments.types.increase')}</SelectItem>}
                      {canDecrease && <SelectItem value="decrease">{t('stockAdjustments.types.decrease')}</SelectItem>}
                      {canSetActual && <SelectItem value="set_actual">{t('stockAdjustments.types.set_actual')}</SelectItem>}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label>{adjustmentType === 'set_actual'
                    ? t('stockAdjustments.actualQuantity')
                    : t('stockAdjustments.quantity')}</Label>
                  <Input
                    type="number"
                    min="0"
                    step={selectedProduct && isDecimalUnit(selectedProduct.unit) ? 'any' : '1'}
                    value={quantity}
                    onChange={(event) => setQuantity(event.target.value)}
                  />
                </div>
                <div className="space-y-1">
                  <Label>{t('stockAdjustments.reason')}</Label>
                  <Select value={reason} onValueChange={setReason}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {REASONS.map((item) => (
                        <SelectItem key={item} value={item}>{t(`stockAdjustments.reasons.${item}`)}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
              {reason === 'other' && (
                <div className="space-y-1">
                  <Label>{t('stockAdjustments.customReason')}</Label>
                  <Input value={reasonDetails} onChange={(event) => setReasonDetails(event.target.value)} maxLength={500} />
                </div>
              )}
              {canSetUnitCost && adjustmentType === 'increase' && (
                <div className="max-w-xs space-y-1">
                  <Label>{t('stockAdjustments.unitCostOptional')}</Label>
                  <Input type="number" min="0" step="any" value={unitCost} onChange={(event) => setUnitCost(event.target.value)} />
                </div>
              )}
              <div className="flex flex-wrap items-end justify-between gap-3">
                <div className="text-sm text-muted-foreground">
                  {selectedProduct && calculatedStock !== null && (
                    <>
                      {t('stockAdjustments.previous')}: <strong className="text-foreground">{selectedProduct.stock} {selectedProduct.unit}</strong>
                      {' · '}
                      {t('stockAdjustments.new')}: <strong className={calculatedStock < selectedProduct.stock ? 'text-rose-600' : calculatedStock > selectedProduct.stock ? 'text-emerald-600' : 'text-foreground'}>
                        {calculatedStock} {selectedProduct.unit}
                      </strong>
                    </>
                  )}
                </div>
                <Button onClick={handleAdjustment} disabled={saving || !selectedProduct || !quantity.trim()}>
                  {saving ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
                  {t('stockAdjustments.confirmAdjustment')}
                </Button>
              </div>
            </Card>
          )}

          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {summaryCards.map((card) => (
              <Card key={card.label} className="p-4">
                <p className="text-sm text-muted-foreground">{card.label}</p>
                <p className={`mt-1 text-2xl font-semibold ${card.className}`}>{card.value}</p>
              </Card>
            ))}
          </div>

          {report && (
            <div className="grid gap-4 lg:grid-cols-3">
              {reportGroups.map((group) => (
                <Card key={group.title} className="p-4">
                  <h4 className="mb-3 font-semibold">{group.title}</h4>
                  <div className="space-y-2 text-sm">
                    {group.entries.slice(0, 5).map((entry) => (
                      <div key={entry.id} className="flex justify-between gap-3">
                        <span className="truncate">{entry.label}</span>
                        <span className="shrink-0 text-muted-foreground">{entry.count}</span>
                      </div>
                    ))}
                    {group.entries.length === 0 && <p className="text-muted-foreground">{t('stockAdjustments.noData')}</p>}
                  </div>
                </Card>
              ))}
            </div>
          )}

          <Card className="space-y-4 p-4">
            <div className="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
              <div>
                <h4 className="font-semibold">{t('stockAdjustments.history')}</h4>
                <p className="text-sm text-muted-foreground">{t('stockAdjustments.historyDescription')}</p>
              </div>
              <div className="flex flex-wrap gap-2">
                {canExport && (
                  <Button variant="outline" size="sm" onClick={exportCsv} disabled={totalCount === 0}>
                    <Download className="mr-2 h-4 w-4" /> CSV
                  </Button>
                )}
                {canPrint && (
                  <Button variant="outline" size="sm" onClick={() => window.print()}>
                    <Printer className="mr-2 h-4 w-4" /> {t('common.print')}
                  </Button>
                )}
              </div>
            </div>
            <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
              <Input value={search} onChange={(event) => { setSearch(event.target.value); setPage(0); }} placeholder={t('stockAdjustments.search')} />
              <Select value={preset} onValueChange={(value) => { setPreset(value as DatePreset); setPage(0); }}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="today">{t('stockAdjustments.periods.today')}</SelectItem>
                  <SelectItem value="yesterday">{t('stockAdjustments.periods.yesterday')}</SelectItem>
                  <SelectItem value="last7">{t('stockAdjustments.periods.last7')}</SelectItem>
                  <SelectItem value="last30">{t('stockAdjustments.periods.last30')}</SelectItem>
                  <SelectItem value="month">{t('stockAdjustments.periods.month')}</SelectItem>
                  <SelectItem value="custom">{t('stockAdjustments.periods.custom')}</SelectItem>
                </SelectContent>
              </Select>
              <Select value={typeFilter} onValueChange={(value) => { setTypeFilter(value); setPage(0); }}>
                <SelectTrigger><SelectValue placeholder={t('stockAdjustments.type')} /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">{t('common.all')}</SelectItem>
                  <SelectItem value="increase">{t('stockAdjustments.types.increase')}</SelectItem>
                  <SelectItem value="decrease">{t('stockAdjustments.types.decrease')}</SelectItem>
                  <SelectItem value="set_actual">{t('stockAdjustments.types.set_actual')}</SelectItem>
                </SelectContent>
              </Select>
              <Select value={reasonFilter} onValueChange={(value) => { setReasonFilter(value); setPage(0); }}>
                <SelectTrigger><SelectValue placeholder={t('stockAdjustments.reason')} /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">{t('common.all')}</SelectItem>
                  {REASONS.map((item) => (
                    <SelectItem key={item} value={item}>{t(`stockAdjustments.reasons.${item}`)}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Select value={employeeFilter} onValueChange={(value) => { setEmployeeFilter(value); setPage(0); }}>
                <SelectTrigger><SelectValue placeholder={t('stockAdjustments.adjustedBy')} /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">{t('common.all')}</SelectItem>
                  {employees.filter((employee) => employee.user_id).map((employee) => (
                    <SelectItem key={employee.user_id!} value={employee.user_id!}>{employee.name || employee.user_id}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            {preset === 'custom' && (
              <div className="flex flex-wrap gap-3">
                <div className="space-y-1"><Label>{t('stockAdjustments.from')}</Label><Input type="date" value={customFrom} onChange={(event) => { setCustomFrom(event.target.value); setPage(0); }} /></div>
                <div className="space-y-1"><Label>{t('stockAdjustments.to')}</Label><Input type="date" value={customTo} onChange={(event) => { setCustomTo(event.target.value); setPage(0); }} /></div>
              </div>
            )}
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('stockAdjustments.id')}</TableHead>
                    <TableHead>{t('stockAdjustments.date')}</TableHead>
                    <TableHead>{t('stockAdjustments.product')}</TableHead>
                    <TableHead>{t('stockAdjustments.previous')}</TableHead>
                    <TableHead>{t('stockAdjustments.type')}</TableHead>
                    <TableHead>{t('stockAdjustments.quantity')}</TableHead>
                    <TableHead>{t('stockAdjustments.new')}</TableHead>
                    <TableHead>{t('stockAdjustments.reason')}</TableHead>
                    <TableHead>{t('stockAdjustments.adjustedBy')}</TableHead>
                    <TableHead>{t('stockAdjustments.notes')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {historyLoading ? (
                    <TableRow><TableCell colSpan={10} className="py-8 text-center text-muted-foreground">
                      <span className="inline-flex items-center gap-2">
                        <Loader2 className="h-4 w-4 animate-spin" /> {t('stockAdjustments.loadingHistory')}
                      </span>
                    </TableCell></TableRow>
                  ) : historyError ? (
                    <TableRow><TableCell colSpan={10} className="py-8 text-center text-destructive">{historyError}</TableCell></TableRow>
                  ) : rows.length === 0 ? (
                    <TableRow><TableCell colSpan={10} className="py-8 text-center text-muted-foreground">{t('stockAdjustments.noData')}</TableCell></TableRow>
                  ) : rows.map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="font-mono text-xs">{row.id.slice(0, 8)}</TableCell>
                      <TableCell className="whitespace-nowrap">{new Date(row.adjusted_at).toLocaleString(locale)}</TableCell>
                      <TableCell>
                        <div className="font-medium">{row.product_name}</div>
                        <div className="text-xs text-muted-foreground">{row.sku || row.barcode || '—'}</div>
                      </TableCell>
                      <TableCell>{row.previous_quantity} {row.unit}</TableCell>
                      <TableCell>
                        <Badge className={row.difference > 0
                          ? 'bg-emerald-100 text-emerald-700'
                          : row.difference < 0
                            ? 'bg-rose-100 text-rose-700'
                            : 'bg-muted text-foreground'}>
                          {row.difference > 0 ? <ArrowUp className="mr-1 h-3 w-3" /> : row.difference < 0 ? <ArrowDown className="mr-1 h-3 w-3" /> : null}
                          {t(`stockAdjustments.types.${row.adjustment_type}`)}
                        </Badge>
                      </TableCell>
                      <TableCell>{row.quantity} {row.unit}</TableCell>
                      <TableCell>{row.new_quantity} {row.unit}</TableCell>
                      <TableCell>
                        {t(`stockAdjustments.reasons.${row.reason}`)}
                        {row.reason === 'other' && row.reason_details ? `: ${row.reason_details}` : ''}
                      </TableCell>
                      <TableCell>{row.adjusted_by || '—'}</TableCell>
                      <TableCell className="max-w-48 truncate">{row.notes || row.reason_details || '—'}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            <div className="flex items-center justify-between gap-3 text-sm text-muted-foreground">
              <span>{totalCount} {t('stockAdjustments.records')}</span>
              <div className="flex items-center gap-2">
                <Button variant="outline" size="sm" disabled={page === 0} onClick={() => setPage((value) => value - 1)}>{t('common.previous')}</Button>
                <span>{page + 1} / {pageCount}</span>
                <Button variant="outline" size="sm" disabled={page + 1 >= pageCount} onClick={() => setPage((value) => value + 1)}>{t('common.next')}</Button>
              </div>
            </div>
          </Card>
        </>
      )}
    </div>
  );
}
