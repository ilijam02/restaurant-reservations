import { FallbackImage } from "@/components/fallback-image";

// image_url is nullable in the DB - when it's null, or the file can't be
// loaded, this renders a placeholder instead of reading a stored default from
// the database. It's an inline SVG (not a static file) specifically so it can
// respond to dark: like the rest of the design system.
export function MenuItemImage({
  imageUrl,
  alt,
  className,
}: {
  imageUrl: string | null;
  alt: string;
  className?: string;
}) {
  const placeholder = (
    <svg
      viewBox="0 0 160 90"
      role="img"
      aria-label={alt}
      className={className}
      // Drawn 16:9 to match the customer menu cards (same shape as the
      // restaurant images). The plate and cutlery sit inside the central
      // square of the canvas, so "slice" can also crop it to a square (the
      // owner list thumbnails and editor preview) without cutting them off.
      preserveAspectRatio="xMidYMid slice"
    >
      <rect width="160" height="90" className="fill-stone-100 dark:fill-stone-700" />
      <g transform="translate(30 -5)">
        <circle cx="50" cy="50" r="30" className="fill-none stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" />
        <circle cx="50" cy="50" r="21" className="fill-none stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" />
        <g className="stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" strokeLinecap="round">
          <line x1="27" y1="28" x2="27" y2="42" />
          <line x1="31" y1="28" x2="31" y2="42" />
          <line x1="27" y1="42" x2="29" y2="46" />
          <line x1="29" y1="46" x2="29" y2="72" />
          <path d="M73 28 v16 a4 4 0 0 1 -4 4 v0 v24" fill="none" />
        </g>
      </g>
    </svg>
  );

  if (!imageUrl) return placeholder;
  return <FallbackImage src={imageUrl} alt={alt} className={className} fallback={placeholder} />;
}
