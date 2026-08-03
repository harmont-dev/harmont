export function LoadingSkeleton(props: { rows?: number; height?: number }) {
  const count = () => props.rows ?? 3;
  const h = () => props.height ?? 42;
  return (
    <div class="flex flex-col gap-2">
      {Array.from({ length: count() }, () => (
        <div
          class="bg-bg-raise border border-border rounded-[2px] animate-pulse"
          style={{ height: `${h()}px` }}
        />
      ))}
    </div>
  );
}
