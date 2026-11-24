import type { IScannerControls } from '@zxing/browser';

export type CameraDirection = 'environment' | 'user';
export type CameraPrerequisiteError = 'secure-context' | 'unavailable';

export function getCameraPrerequisiteError(
  isSecureContext: boolean,
  hasGetUserMedia: boolean
): CameraPrerequisiteError | null {
  if (!isSecureContext) return 'secure-context';
  if (!hasGetUserMedia) return 'unavailable';
  return null;
}

type BarcodeResult = {
  getText: () => string;
};

type DecodeFromConstraints = (
  constraints: MediaStreamConstraints,
  video: HTMLVideoElement,
  callback: (result?: BarcodeResult) => void
) => Promise<IScannerControls>;

export function createPOSCameraSession(
  decodeFromConstraints: DecodeFromConstraints,
  video: HTMLVideoElement,
  direction: CameraDirection,
  onDetected: (barcode: string) => void
) {
  let cancelled = false;
  let controls: IScannerControls | undefined;
  let controlsStopped = false;
  let scanned = false;

  const stop = () => {
    cancelled = true;
    if (controls && !controlsStopped) {
      controlsStopped = true;
      controls.stop();
    }
    video.srcObject = null;
  };

  const started = decodeFromConstraints(
    {
      audio: false,
      video: {
        facingMode: { ideal: direction },
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
    },
    video,
    (result) => {
      if (!result || cancelled || scanned) return;
      const barcode = result.getText().trim();
      if (!barcode) return;
      scanned = true;
      stop();
      onDetected(barcode);
    }
  ).then((nextControls) => {
    controls = nextControls;
    if (cancelled) stop();
  });

  return { started, stop };
}
