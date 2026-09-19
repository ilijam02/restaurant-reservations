"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { ACCEPT_ATTRIBUTE, IMAGE_READ_ERROR, resizeImage, validateImageFile } from "@/lib/image-upload";

// What the owner has done to the image this session. Nothing touches storage
// or the database until the parent form's own save - picking, replacing, or
// removing here only changes this value, so cancelling a form never leaves
// an orphaned upload behind.
export type ImageChange = { kind: "unchanged" } | { kind: "replace"; blob: Blob } | { kind: "remove" };

export const UNCHANGED_IMAGE: ImageChange = { kind: "unchanged" };

const BUTTON_CLASSES =
  "rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700";

export function ImagePicker({
  label,
  currentUrl,
  value,
  onChange,
  maxDimension,
  disabled,
  renderImage,
  previewClassName,
}: {
  label: string;
  currentUrl: string | null;
  value: ImageChange;
  onChange: (next: ImageChange) => void;
  maxDimension: number;
  disabled?: boolean;
  // Renders the current image or the null placeholder - the picker itself
  // doesn't know which placeholder (restaurant vs. menu item) applies.
  renderImage: (imageUrl: string | null, className: string) => ReactNode;
  previewClassName: string;
}) {
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  // Object URLs are created when a file is picked (not derived in an effect)
  // and released whenever they're replaced or the picker unmounts.
  const previewUrlRef = useRef<string | null>(null);
  // Also tells an in-flight resize that the picker went away, so it doesn't
  // create an object URL after the cleanup below has already run.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (previewUrlRef.current) URL.revokeObjectURL(previewUrlRef.current);
    };
  }, []);

  function setPreview(blob: Blob | null) {
    if (previewUrlRef.current) URL.revokeObjectURL(previewUrlRef.current);
    previewUrlRef.current = blob ? URL.createObjectURL(blob) : null;
    setPreviewUrl(previewUrlRef.current);
  }

  const shownUrl = value.kind === "remove" ? null : value.kind === "replace" ? previewUrl : currentUrl;
  const hasImage = shownUrl !== null;

  async function handleFile(file: File | undefined) {
    if (!file) return;
    setError(null);

    const validationError = validateImageFile(file);
    if (validationError) {
      setError(validationError);
      return;
    }

    setProcessing(true);
    const blob = await resizeImage(file, maxDimension);
    if (!mountedRef.current) return;
    setProcessing(false);

    if (!blob) {
      setError(IMAGE_READ_ERROR);
      return;
    }
    setPreview(blob);
    onChange({ kind: "replace", blob });
  }

  function handleRemove() {
    setError(null);
    // A stored image has to be remembered as "to remove" until save (this
    // also covers a replacement picked over it). With nothing stored, or
    // when this is the undo of a pending removal, it just goes back to
    // unchanged.
    setPreview(null);
    onChange(currentUrl && value.kind !== "remove" ? { kind: "remove" } : UNCHANGED_IMAGE);
  }

  return (
    <div className="space-y-2">
      <span className="block text-sm font-medium">{label}</span>
      <div className="flex items-center gap-4">
        {renderImage(shownUrl, previewClassName)}
        <div className="space-y-2">
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              disabled={disabled || processing}
              onClick={() => inputRef.current?.click()}
              className={BUTTON_CLASSES}
            >
              {processing ? "Obrada..." : hasImage ? "Promeni sliku" : "Dodaj sliku"}
            </button>
            {(hasImage || value.kind === "remove") && (
              <button
                type="button"
                disabled={disabled || processing}
                onClick={handleRemove}
                className={`${BUTTON_CLASSES} ${value.kind === "remove" ? "" : "text-red-600 dark:text-red-400"}`}
              >
                {value.kind === "remove" ? "Poništi uklanjanje" : "Ukloni sliku"}
              </button>
            )}
          </div>
          <p className="text-xs text-stone-600 dark:text-stone-400">JPEG, PNG ili WebP.</p>
        </div>
      </div>
      <input
        ref={inputRef}
        id={inputId}
        type="file"
        accept={ACCEPT_ATTRIBUTE}
        aria-label={label}
        className="sr-only"
        tabIndex={-1}
        onChange={(event) => {
          void handleFile(event.target.files?.[0]);
          // Reset so picking the same file again after removing it still fires onChange.
          event.target.value = "";
        }}
      />
      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
