'use client';

import { useEffect, useRef, useState } from 'react';
import { Camera, Loader2, RefreshCw, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { useTranslation } from '@/hooks/use-translation';
import {
  createPOSCameraSession,
  getCameraPrerequisiteError,
  type CameraDirection,
} from '@/lib/pos-camera-session';

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDetected: (barcode: string) => void;
};

export function POSCameraScanner({ open, onOpenChange, onDetected }: Props) {
  const { t } = useTranslation();
  const videoRef = useRef<HTMLVideoElement>(null);
  const scannedRef = useRef(false);
  const onDetectedRef = useRef(onDetected);
  const [cameraDirection, setCameraDirection] = useState<CameraDirection>('environment');
  const [starting, setStarting] = useState(false);
  const [cameraError, setCameraError] = useState('');

  useEffect(() => {
    onDetectedRef.current = onDetected;
  }, [onDetected]);

  useEffect(() => {
    if (!open) return;

    let cancelled = false;
    let session: ReturnType<typeof createPOSCameraSession> | undefined;
    const video = videoRef.current;
    scannedRef.current = false;
    setCameraError('');
    setStarting(true);

    const startCamera = async () => {
      const prerequisiteError = getCameraPrerequisiteError(
        window.isSecureContext,
        Boolean(navigator.mediaDevices?.getUserMedia)
      );
      if (prerequisiteError === 'secure-context') {
        setCameraError(t('pos.cameraRequiresSecureContext'));
        setStarting(false);
        return;
      }
      if (prerequisiteError === 'unavailable') {
        setCameraError(t('pos.cameraUnavailable'));
        setStarting(false);
        return;
      }

      try {
        const { BrowserMultiFormatReader } = await import('@zxing/browser');
        if (!video || cancelled) return;

        const reader = new BrowserMultiFormatReader(undefined, { delayBetweenScanAttempts: 250 });
        session = createPOSCameraSession(
          (constraints, targetVideo, callback) =>
            reader.decodeFromConstraints(constraints, targetVideo, (result) => callback(result)),
          video,
          cameraDirection,
          (barcode) => {
            if (scannedRef.current) return;
            scannedRef.current = true;
            onDetectedRef.current(barcode);
          }
        );
        if (cancelled) session.stop();
        await session.started;
      } catch (error) {
        if (cancelled) return;
        console.error('[POS camera scanner] Could not start camera:', error);
        const errorName = error instanceof Error ? error.name : '';
        if (errorName === 'NotAllowedError' || errorName === 'SecurityError') {
          setCameraError(t('pos.cameraPermissionDenied'));
        } else if (errorName === 'NotFoundError' || errorName === 'DevicesNotFoundError') {
          setCameraError(t('pos.cameraNotFound'));
        } else {
          setCameraError(t('pos.cameraUnavailable'));
        }
      } finally {
        if (!cancelled) setStarting(false);
      }
    };

    void startCamera();
    return () => {
      cancelled = true;
      session?.stop();
      if (video) video.srcObject = null;
    };
  }, [cameraDirection, open, t]);

  const switchCamera = () => {
    setCameraDirection((current) => current === 'environment' ? 'user' : 'environment');
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="w-[calc(100%-1rem)] max-w-lg gap-4 p-4 sm:p-6">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Camera className="h-5 w-5" />
            {t('pos.cameraScan')}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-3">
          <div className="relative aspect-video overflow-hidden rounded-lg bg-black">
            <video
              ref={videoRef}
              autoPlay
              muted
              playsInline
              className="h-full w-full object-cover"
              aria-label={t('pos.cameraPreview')}
            />
            <div className="pointer-events-none absolute inset-[15%] rounded-lg border-2 border-amber-400/90 shadow-[0_0_0_999px_rgba(0,0,0,0.28)]" />
            {starting && (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 bg-black/55 text-white">
                <Loader2 className="h-7 w-7 animate-spin" />
                <span className="text-sm">{t('pos.cameraStarting')}</span>
              </div>
            )}
          </div>
          {cameraError ? (
            <p role="alert" className="text-sm text-destructive">{cameraError}</p>
          ) : (
            <p className="text-center text-sm text-muted-foreground">{t('pos.cameraInstructions')}</p>
          )}
        </div>

        <DialogFooter className="flex-row gap-2 sm:justify-between sm:space-x-0">
          <Button type="button" variant="outline" onClick={switchCamera} disabled={starting}>
            <RefreshCw className="mr-2 h-4 w-4" />
            {t('pos.switchCamera')}
          </Button>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            <X className="mr-2 h-4 w-4" />
            {t('common.close')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
