"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

// An <img> that shows `fallback` (the inline SVG placeholder) instead of a
// broken-image icon when the file can't be loaded - e.g. a restaurant's image
// file was removed from Storage while its image_url still points at it. The
// failed URL is remembered rather than a plain boolean, so picking a new image
// (a new src) gets a fresh attempt.
//
// onError alone isn't enough: an image that fails before React has hydrated
// fires its error event before the handler is attached, so it's also checked
// once after mount (complete, but no pixels).
export function FallbackImage({
  src,
  alt,
  className,
  loading,
  fallback,
}: {
  src: string;
  alt: string;
  className?: string;
  loading?: "lazy" | "eager";
  fallback: ReactNode;
}) {
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const imageRef = useRef<HTMLImageElement>(null);

  useEffect(() => {
    const image = imageRef.current;
    if (image && image.complete && image.naturalWidth === 0) {
      setFailedSrc(src);
    }
  }, [src]);

  if (failedSrc === src) return <>{fallback}</>;

  // eslint-disable-next-line @next/next/no-img-element
  return <img ref={imageRef} src={src} alt={alt} loading={loading} className={className} onError={() => setFailedSrc(src)} />;
}
