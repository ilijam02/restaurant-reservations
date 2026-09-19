// image_url is nullable in the DB and there's no owner upload UI yet (see
// the "Menu items - image" decision in ISSUES.md) - when it's null, this
// renders a placeholder instead of reading a stored default from the
// database. It's an inline SVG (not a static file) specifically so it can
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
  if (imageUrl) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={imageUrl} alt={alt} className={className} />;
  }

  return (
    <svg
      viewBox="0 0 100 100"
      role="img"
      aria-label={alt}
      className={className}
      // "slice" so the artwork fills a non-square box instead of
      // letterboxing (the customer menu cards are square, but the owner
      // list thumbnails and any future layout may not be).
      preserveAspectRatio="xMidYMid slice"
    >
      <rect width="100" height="100" className="fill-stone-100 dark:fill-stone-700" />
      <circle cx="50" cy="50" r="30" className="fill-none stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" />
      <circle cx="50" cy="50" r="21" className="fill-none stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" />
      <g className="stroke-orange-700 dark:stroke-accent" strokeWidth="2.5" strokeLinecap="round">
        <line x1="27" y1="28" x2="27" y2="42" />
        <line x1="31" y1="28" x2="31" y2="42" />
        <line x1="27" y1="42" x2="29" y2="46" />
        <line x1="29" y1="46" x2="29" y2="72" />
        <path d="M73 28 v16 a4 4 0 0 1 -4 4 v0 v24" fill="none" />
      </g>
    </svg>
  );
}
