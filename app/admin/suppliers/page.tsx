'use client';

import { useCallback, useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import { Plus, Edit2, Trash2, Truck, Search, Mail, Phone, MapPin, Upload, Eye, Users, Wallet } from 'lucide-react';
import Link from 'next/link';
import { Card } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog';
import { supabase } from '@/lib/supabase';
import type { Supplier } from '@/types';
import { toast } from 'sonner';
import { useTranslation } from '@/hooks/use-translation';
import { useConfirmation } from '@/hooks/use-confirmation';
import { GenericImportCSVDialog } from '@/components/generic-import-csv-dialog';

const emptySupplierForm = {
  name: '',
  company_name: '',
  contact_person: '',
  email: '',
  phone: '',
  address: '',
  city: '',
  country: '',
};

export default function SuppliersPage() {
  const { t, locale } = useTranslation();
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [dialogOpen, setDialogOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);
  const [editing, setEditing] = useState<Supplier | null>(null);
  const [form, setForm] = useState({ ...emptySupplierForm });
  const { confirmUpdate, confirmDelete, dialog: confirmationDialog } = useConfirmation();

  const loadData = useCallback(async () => {
    const { data, error } = await supabase.from('suppliers').select('*').order('name');
    if (error || !data) {
      console.error('Could not load suppliers', error);
      toast.error(error?.message || t('suppliers.loadFailed'));
      setLoading(false);
      return;
    }
    setSuppliers(data);
    setLoading(false);
  }, [t]);

  useEffect(() => { void loadData(); }, [loadData]);

  const normalizedSearch = search.trim().toLowerCase();
  const filtered = suppliers.filter((supplier) => !normalizedSearch || [
    supplier.name,
    supplier.company_name,
    supplier.contact_person,
    supplier.email,
    supplier.phone,
  ].some((value) => value?.toLowerCase().includes(normalizedSearch)));
  const formatMoney = (value: number) => `৳${Number(value || 0).toLocaleString(locale === 'bn' ? 'bn-BD' : 'en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  const handleSave = async () => {
    if (!form.name) { toast.error(t('suppliers.nameRequired')); return; }
    if (editing) {
      const supplierId = editing.id;
      await confirmUpdate({
        successMessage: t('suppliers.updateSuccess'),
        action: async () => {
          const { error } = await supabase.from('suppliers').update(form).eq('id', supplierId);
          if (error) throw error;
          setDialogOpen(false);
          setEditing(null);
          setForm({ ...emptySupplierForm });
          await loadData();
        },
      });
      return;
    } else {
      const { error: insertError } = await supabase
        .from('suppliers')
        .insert({ ...form, status: 'active', balance: 0 });
      if (insertError) {
        toast.error(t('common.createFailed'));
        return;
      }
      toast.success(t('suppliers.createSuccess'));
    }
    setDialogOpen(false); setEditing(null); setForm({ ...emptySupplierForm });
    await loadData();
  };

  const handleDelete = async (id: string) => {
    const supplier = suppliers.find((item) => item.id === id);
    await confirmDelete({
      recordName: supplier?.name || id,
      successMessage: t('suppliers.deleteSuccess'),
      action: async () => {
        const { error } = await supabase.from('suppliers').delete().eq('id', id);
        if (error) throw error;
        await loadData();
      },
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-4">
        <div>
          <h2 className="text-2xl font-bold font-heading">{t('suppliers.title')}</h2>
          <p className="text-sm text-muted-foreground">{t('suppliers.subtitle')}</p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => setImportOpen(true)}><Upload className="w-4 h-4 mr-2" /> Import CSV</Button>
          <Button size="sm" className="bg-gradient-to-r from-slate-800 to-black" onClick={() => { setEditing(null); setForm({ ...emptySupplierForm }); setDialogOpen(true); }}>
            <Plus className="w-4 h-4 mr-2" /> {t('suppliers.addSupplier')}
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        {[
          { label: t('suppliers.totalSuppliers'), value: suppliers.length, icon: Users, color: 'from-slate-800 to-black' },
          { label: t('suppliers.activeSuppliers'), value: suppliers.filter((supplier) => supplier.status === 'active').length, icon: Truck, color: 'from-emerald-500 to-teal-600' },
          { label: t('suppliers.totalPurchases'), value: formatMoney(suppliers.reduce((sum, supplier) => sum + Number(supplier.total_buy || 0), 0)), icon: Wallet, color: 'from-blue-500 to-cyan-600' },
          { label: t('suppliers.totalDue'), value: formatMoney(suppliers.reduce((sum, supplier) => sum + Number(supplier.total_due || 0) + Number(supplier.previous_due || 0), 0)), icon: Wallet, color: 'from-amber-500 to-orange-600' },
        ].map((stat, index) => (
          <motion.div key={stat.label} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.05 }}>
            <Card className="p-4">
              <div className="flex items-center gap-3">
                <div className={`flex h-10 w-10 items-center justify-center rounded-lg bg-gradient-to-br ${stat.color}`}>
                  <stat.icon className="h-5 w-5 text-white" />
                </div>
                <div className="min-w-0"><p className="text-xs text-muted-foreground">{stat.label}</p><p className="truncate text-xl font-bold">{stat.value}</p></div>
              </div>
            </Card>
          </motion.div>
        ))}
      </div>

      <div className="relative max-w-sm">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
        <Input placeholder={t('suppliers.search')} value={search} onChange={(e) => setSearch(e.target.value)} className="pl-10" />
      </div>

      <Card className="overflow-hidden">
        <div className="overflow-x-auto">
          <Table className="min-w-[900px]">
            <TableHeader>
              <TableRow>
                <TableHead>{t('common.name')}</TableHead>
                <TableHead>{t('suppliers.companyName')}</TableHead>
                <TableHead>{t('common.contact')}</TableHead>
                <TableHead>{t('suppliers.totalPurchases')}</TableHead>
                <TableHead>{t('suppliers.totalPaid')}</TableHead>
                <TableHead>{t('suppliers.totalDue')}</TableHead>
                <TableHead>{t('common.status')}</TableHead>
                <TableHead className="text-right">{t('common.actions')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {loading ? Array.from({ length: 5 }).map((_, index) => (
                <TableRow key={index}>{Array.from({ length: 8 }).map((__, cellIndex) => <TableCell key={cellIndex}><div className="h-4 animate-pulse rounded bg-muted" /></TableCell>)}</TableRow>
              )) : filtered.length === 0 ? (
                <TableRow><TableCell colSpan={8} className="py-12 text-center text-muted-foreground">{t('suppliers.noSuppliers')}</TableCell></TableRow>
              ) : filtered.map((supplier, index) => (
                <motion.tr key={supplier.id} initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: index * 0.02 }} className="hover:bg-muted/50">
                  <TableCell className="font-medium">
                    <p>{supplier.name}</p>
                    {supplier.contact_person && <p className="text-xs font-normal text-muted-foreground">{supplier.contact_person}</p>}
                  </TableCell>
                  <TableCell>{supplier.company_name || '—'}</TableCell>
                  <TableCell>
                    <div className="space-y-0.5">
                      {supplier.email && <p className="flex items-center gap-1 text-xs text-muted-foreground"><Mail className="h-3 w-3" />{supplier.email}</p>}
                      {supplier.phone && <p className="flex items-center gap-1 text-xs text-muted-foreground"><Phone className="h-3 w-3" />{supplier.phone}</p>}
                      {(supplier.address || supplier.city || supplier.country) && <p className="flex items-center gap-1 text-xs text-muted-foreground"><MapPin className="h-3 w-3" />{[supplier.address, supplier.city, supplier.country].filter(Boolean).join(', ')}</p>}
                    </div>
                  </TableCell>
                  <TableCell className="font-medium">{formatMoney(Number(supplier.total_buy || 0))}</TableCell>
                  <TableCell className="font-medium text-emerald-600">{formatMoney(Number(supplier.total_paid || 0))}</TableCell>
                  <TableCell className={Number(supplier.total_due || 0) + Number(supplier.previous_due || 0) > 0 ? 'font-medium text-amber-600' : 'text-muted-foreground'}>
                    {formatMoney(Number(supplier.total_due || 0) + Number(supplier.previous_due || 0))}
                  </TableCell>
                  <TableCell><Badge variant="secondary" className={supplier.status === 'active' ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400' : ''}>{t(supplier.status === 'active' ? 'common.active' : 'common.inactive')}</Badge></TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-1">
                      <Link href={`/admin/suppliers/${supplier.id}`}>
                        <Button size="icon" variant="ghost" className="h-8 w-8" title={t('suppliers.viewProfile')}><Eye className="h-4 w-4" /></Button>
                      </Link>
                      <Button size="icon" variant="ghost" className="h-8 w-8" title={t('suppliers.editSupplier')} onClick={() => {
                        setEditing(supplier);
                        setForm({
                          name: supplier.name,
                          company_name: supplier.company_name || '',
                          contact_person: supplier.contact_person || '',
                          email: supplier.email || '',
                          phone: supplier.phone || '',
                          address: supplier.address || '',
                          city: supplier.city || '',
                          country: supplier.country || '',
                        });
                        setDialogOpen(true);
                      }}>
                        <Edit2 className="h-4 w-4" />
                      </Button>
                      <Button size="icon" variant="ghost" className="h-8 w-8 text-rose-600" title={t('suppliers.deleteSupplier')} onClick={() => void handleDelete(supplier.id)}>
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  </TableCell>
                </motion.tr>
              ))}
            </TableBody>
          </Table>
        </div>
      </Card>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-lg">
          <DialogHeader><DialogTitle>{editing ? t('suppliers.editSupplier') : t('suppliers.addSupplier')}</DialogTitle></DialogHeader>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="space-y-2 col-span-full"><Label>{t('common.name')} *</Label><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('suppliers.companyName')}</Label><Input value={form.company_name} onChange={(e) => setForm({ ...form, company_name: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('suppliers.contactPerson')}</Label><Input value={form.contact_person} onChange={(e) => setForm({ ...form, contact_person: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('common.phone')}</Label><Input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('common.email')}</Label><Input type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('suppliers.city')}</Label><Input value={form.city} onChange={(e) => setForm({ ...form, city: e.target.value })} /></div>
            <div className="space-y-2 col-span-full"><Label>{t('common.address')}</Label><Input value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} /></div>
            <div className="space-y-2"><Label>{t('suppliers.country')}</Label><Input value={form.country} onChange={(e) => setForm({ ...form, country: e.target.value })} /></div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDialogOpen(false)}>{t('common.cancel')}</Button>
            <Button className="bg-gradient-to-r from-slate-800 to-black" onClick={handleSave}>{editing ? t('common.update') : t('common.create')}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <GenericImportCSVDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        title={t('suppliers.title')}
        tableName="suppliers"
        templateName="supplier-import-template.csv"
        fields={[
          { key: 'name', label: t('common.name'), aliases: ['name', 'supplier', 'supplier_name', 'supplier name', 'সাপ্লাইয়ার', 'সরবরাহকারী'], required: true },
          { key: 'company_name', label: t('suppliers.companyName'), aliases: ['company_name', 'company name', 'company', 'প্রতিষ্ঠানের নাম'] },
          { key: 'contact_person', label: t('suppliers.contactPerson'), aliases: ['contact_person', 'contact person', 'যোগাযোগকারী'] },
          { key: 'email', label: t('common.email'), aliases: ['email', 'email_address', 'ইমেইল'] },
          { key: 'phone', label: t('common.phone'), aliases: ['phone', 'mobile', 'phone_number', 'মোবাইল'] },
          { key: 'address', label: t('common.address'), aliases: ['address', 'location', 'ঠিকানা'] },
          { key: 'city', label: t('suppliers.city'), aliases: ['city', 'town', 'শহর'] },
          { key: 'country', label: t('suppliers.country'), aliases: ['country', 'দেশ'] },
          { key: 'status', label: t('common.status'), aliases: ['status', 'স্ট্যাটাস'] },
        ]}
        existingNames={suppliers.map((item) => item.name)}
        preparePayload={async (values) => ({
          name: values.name,
          company_name: values.company_name || null,
          contact_person: values.contact_person || null,
          email: values.email || null,
          phone: values.phone || null,
          address: values.address || null,
          city: values.city || null,
          country: values.country || null,
          status: values.status?.toLowerCase() === 'inactive' ? 'inactive' : 'active',
          balance: 0,
        })}
        onComplete={loadData}
      />
      {confirmationDialog}
    </div>
  );
}
