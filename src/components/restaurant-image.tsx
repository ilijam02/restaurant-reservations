// restaurants.image_url is nullable (an owner may never upload one) - when
// it's null this renders an inline SVG placeholder rather than a stored
// default, same approach and reasoning as MenuItemImage (inline so it can
// respond to dark: like the rest of the design system).
export function RestaurantImage({
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
    return <img src={imageUrl} alt={alt} loading="lazy" className={className} />;
  }

  return (
    <svg
      viewBox="0 0 160 100"
      role={alt ? "img" : undefined}
      aria-label={alt || undefined}
      aria-hidden={alt ? undefined : true}
      className={className}
      preserveAspectRatio="xMidYMid slice"
    >
      <rect width="160" height="100" className="fill-stone-100 dark:fill-stone-700" />
      <g className="stroke-orange-700 dark:stroke-accent" fill="none" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
        <path d="M50 78 V44 h60 v34" />
        <path d="M44 44 L80 24 L116 44" />
        <path d="M70 78 V58 h20 v20" />
      </g>
    </svg>
  );
}
