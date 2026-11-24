'use client';

import { useRef, useState } from 'react';
import { Download, FileSpreadsheet, Loader2, Upload, X } from 'lucide-react';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { toast } from 'sonner';
import { decodeCSVBuffer, CsvEncodingError, CsvParseError, parseCSV, downloadFile } from '@/lib/csv-import';
import { hasMissingRequiredCsvValues } from '@/lib/csv-validation';
import { escapeCsvCell } from '@/lib/safe-export';
import { supabase } from '@/lib/supabase';
import { useTranslation } from '@/hooks/use-translation';

export type GenericImportField = {
  key: string;
  label: string;
  aliases: string[];
  required?: boolean;
};

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  tableName: string;
  templateName: string;
  fields: GenericImportField[];
  existingNames: string[];
  duplicateField?: string;
  preparePayload?: (values: Record<string, string>) => Promise<Record<string, unknown>>;
  onComplete: () => void;
};

export function GenericImportCSVDialog({
  open, onOpenChange, title, tableName, templateName, fields, existingNames,
  duplicateField = 'name', preparePayload, onComplete,
}: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [step, setStep] = useState<'upload' | 'mapping' | 'preview' | 'importing' | 'result'>('upload');
  const [fileName, setFileName] = useState('');
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<string[][]>([]);
  const [mapping, setMapping] = useState<Record<number, string | null>>({});
  const [imported, setImported] = useState(0);
  const [failed, setFailed] = useState(0);
  const [skipped, setSkipped] = useState(0);
  const { t } = useTranslation();

  const reset = () => {
    setStep('upload');
    setFileName('');
    setHeaders([]);
    setRows([]);
    setMapping({});
    setImported(0);
    setFailed(0);
    setSkipped(0);
  };

  const handleClose = (value: boolean) => {
    if (!value) reset();
    onOpenChange(value);
  };

  const autoMap = (csvHeaders: string[]) => {
    const result: Record<number, string | null> = {};
    csvHeaders.forEach((header, index) => {
      const normalized = header.trim().toLowerCase();
      const field = fields.find((item) =>
        item.aliases.some((alias) => alias.trim().toLowerCase() === normalized)
      );
      result[index] = field?.key || null;
    });
    return result;
  };

  const handleFile = async (file: File) => {
    if (!file.name.toLowerCase().endsWith('.csv')) {
      toast.error(t('csvImport.selectCsv'));
      return;
    }
    if (file.size > 10 * 1024 * 1024) {
      toast.error(t('csvImport.fileTooLarge'));
      return;
    }
    try {
      const text = decodeCSVBuffer(await file.arrayBuffer());
      const parsed = parseCSV(text);
      const nonEmptyRows = parsed.rows.filter((row) => row.some((value) => value.trim()));
      if (parsed.headers.length === 0 || nonEmptyRows.length === 0) {
        toast.error(t('csvImport.emptyFile'));
        return;
      }
      setFileName(file.name);
      setHeaders(parsed.headers);
      setRows(nonEmptyRows);
      const mapped = autoMap(parsed.headers);
      setMapping(mapped);
      setStep(parsed.headers.some((_, index) => !mapped[index]) ? 'mapping' : 'preview');
    } catch (error) {
      if (error instanceof CsvEncodingError) toast.error(t('csvImport.invalidEncoding'));
      else if (error instanceof CsvParseError) toast.error(t('csvImport.malformedFile'));
      else {
        console.error(`[${tableName}] Could not read CSV:`, error);
        toast.error(t('csvImport.readFailed'));
      }
    }
  };

  const getValues = (row: string[][][number]) => {
    const values: Record<string, string> = {};
    headers.forEach((_, index) => {
      const key = mapping[index];
      if (key) values[key] = (row[index] || '').trim();
    });
    return values;
  };

  const mappedFields = Object.values(mapping).filter((value): value is string => Boolean(value));
  const missingRequired = fields.filter((field) => field.required && !mappedFields.includes(field.key));
  const previewRows = rows.slice(0, 50);

  const downloadTemplate = () => {
    const csv = '\uFEFF' + [
      fields.map((field) => field.label),
      fields.map((field) => field.key === 'status' ? 'active' : ''),
    ].map((row) => row.map(escapeCsvCell).join(',')).join('\r\n');
    downloadFile(csv, templateName, 'text/csv;charset=utf-8');
  };

  const runImport = async () => {
    if (missingRequired.length > 0) {
      toast.error(`Required columns not mapped: ${missingRequired.map((field) => field.label).join(', ')}`);
      return;
    }
    setStep('importing');
    let count = 0;
    let skippedCount = 0;
    const normalizeDuplicate = (value: string) => duplicateField === 'phone'
      ? value.replace(/[^0-9]/g, '')
      : value.trim().toLowerCase();
    const existing = new Set(existingNames.map(normalizeDuplicate).filter(Boolean));
    const seen = new Set<string>();
    const payloads: Record<string, unknown>[] = [];

    try {
      for (const row of rows) {
        const values = getValues(row);
        if (!values.name?.trim() || hasMissingRequiredCsvValues(fields, values)) {
          skippedCount += 1;
          continue;
        }
        const duplicateSource = values[duplicateField] || (duplicateField === 'name' ? values.name : '');
        const duplicateValue = duplicateSource ? normalizeDuplicate(duplicateSource) : '';
        if (duplicateValue && (existing.has(duplicateValue) || seen.has(duplicateValue))) {
          skippedCount += 1;
          continue;
        }
        if (duplicateValue) seen.add(duplicateValue);
        const payload = preparePayload ? await preparePayload(values) : Object.fromEntries(
          fields.map((field) => [field.key, values[field.key]?.trim() || null])
        );
        payload.status = payload.status || 'active';
        payloads.push(payload);
      }
    } catch (error) {
      console.error(`[${tableName}] CSV preparation failed:`, error);
      toast.error(error instanceof Error ? error.message : 'Could not prepare CSV data');
      setStep('preview');
      return;
    }

    if (payloads.length === 0) {
      toast.error(t('csvImport.noValidRows'));
      setStep('preview');
      return;
    }

    let failedCount = 0;
    try {
      for (let index = 0; index < payloads.length; index += 50) {
        const batch = payloads.slice(index, index + 50);
        const { error } = await supabase.from(tableName).insert(batch);
        if (error) {
          console.error(`[${tableName}] CSV import failed for batch starting at row ${index + 1}:`, error);
          failedCount += batch.length;
        } else {
          count += batch.length;
        }
      }
    } catch (error) {
      console.error(`[${tableName}] CSV import request failed:`, error);
      toast.error(error instanceof Error ? error.message : 'CSV import failed');
      setStep('preview');
      return;
    }
    setImported(count);
    setFailed(failedCount);
    setSkipped(skippedCount);
    if (count > 0) toast.success(t('csvImport.generic.imported', { count }));
    if (failedCount > 0) toast.error(t('csvImport.generic.failed', { count: failedCount }));
    onComplete();
    setStep('result');
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="max-w-4xl max-h-[90vh] overflow-hidden flex flex-col">
        <DialogHeader>
          <DialogTitle>{t('csvImport.generic.title', { name: title })}</DialogTitle>
        </DialogHeader>

        {step === 'upload' && (
          <div className="py-6 space-y-4">
            <div className="border-2 border-dashed rounded-lg p-8 text-center space-y-3">
              <FileSpreadsheet className="w-10 h-10 mx-auto text-muted-foreground" />
              <p className="text-sm text-muted-foreground">{t('csvImport.generic.instructions')}</p>
              <div className="flex justify-center gap-2">
                <Button variant="outline" onClick={() => fileRef.current?.click()}>
                  <Upload className="w-4 h-4 mr-2" /> {t('csvImport.chooseFile')}
                </Button>
                <Button variant="outline" onClick={downloadTemplate}>
                  <Download className="w-4 h-4 mr-2" /> {t('csvImport.downloadTemplate')}
                </Button>
              </div>
              <input
                ref={fileRef}
                type="file"
                accept=".csv,text/csv"
                className="hidden"
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  event.target.value = '';
                  if (file) void handleFile(file);
                }}
              />
            </div>
          </div>
        )}

        {step === 'mapping' && (
          <div className="space-y-4 overflow-auto">
            <div className="text-sm text-muted-foreground">{fileName}</div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('csvImport.csvColumn')}</TableHead>
                  <TableHead>{t('csvImport.applicationField')}</TableHead>
                  <TableHead>{t('csvImport.generic.sample')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {headers.map((header, index) => (
                  <TableRow key={`${header}-${index}`}>
                    <TableCell className="font-medium">{header}</TableCell>
                    <TableCell>
                      <select
                        className="h-9 rounded-md border border-input bg-background px-3 text-sm"
                        value={mapping[index] || ''}
                        onChange={(event) => setMapping({ ...mapping, [index]: event.target.value || null })}
                      >
                        <option value="">{t('csvImport.skip')}</option>
                        {fields.map((field) => (
                          <option key={field.key} value={field.key}>
                            {field.label}{field.required ? ' *' : ''}
                          </option>
                        ))}
                      </select>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{rows[0]?.[index] || '-'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}

        {step === 'preview' && (
          <div className="space-y-3 overflow-hidden">
            <div className="flex items-center justify-between">
              <span className="text-sm text-muted-foreground">{fileName} - {t('csvImport.rowCount', { count: rows.length })}</span>
              {missingRequired.length > 0 && (
                <Badge variant="destructive">{t('csvImport.generic.missing')}: {missingRequired.map((field) => field.label).join(', ')}</Badge>
              )}
            </div>
            <div className="border rounded-md overflow-auto max-h-[55vh]">
              <Table>
                <TableHeader>
                  <TableRow>
                    {fields.map((field) => <TableHead key={field.key}>{field.label}</TableHead>)}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {previewRows.map((row, index) => {
                    const values = getValues(row);
                    return (
                      <TableRow key={index}>
                        {fields.map((field) => <TableCell key={field.key}>{values[field.key] || '-'}</TableCell>)}
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          </div>
        )}

        {step === 'importing' && (
          <div className="py-10 flex flex-col items-center gap-3">
            <Loader2 className="w-8 h-8 animate-spin" />
            <p className="text-sm">{t('csvImport.importing')}</p>
          </div>
        )}
        {step === 'result' && (
          <div className="py-8 text-center space-y-3">
            <h3 className="text-lg font-semibold">{t('csvImport.completed')}</h3>
            <p>{t('csvImport.imported')}: {imported}</p>
            {skipped > 0 && <p>{t('csvImport.skipped')}: {skipped}</p>}
            {failed > 0 && <p className="text-destructive">{t('csvImport.failed')}: {failed}</p>}
          </div>
        )}

        <DialogFooter>
          {step === 'importing' ? null : (
            <>
              <Button variant="outline" onClick={() => handleClose(false)}><X className="w-4 h-4 mr-2" /> {t('common.close')}</Button>
              {step === 'mapping' && (
                <Button onClick={() => setStep('preview')}>{t('csvImport.continuePreview')}</Button>
              )}
              {step === 'preview' && (
                <Button onClick={() => void runImport()}>{t('csvImport.generic.import')}</Button>
              )}
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
