import { createSignal, onCleanup, type Accessor } from "solid-js";

export type PanZoomState = {
  panX: Accessor<number>;
  panY: Accessor<number>;
  zoom: Accessor<number>;
  isDragging: Accessor<boolean>;
  onPanStart: (e: MouseEvent) => void;
  onWheel: (deltaY: number, anchorX: number, anchorY: number) => void;
};

const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const ZOOM_FACTOR = 1.1;

export function usePanZoom(): PanZoomState {
  const [panX, setPanX] = createSignal(0);
  const [panY, setPanY] = createSignal(0);
  const [zoom, setZoom] = createSignal(1);
  const [dragging, setDragging] = createSignal<{ lastX: number; lastY: number } | null>(null);

  const handleMove = (e: MouseEvent) => {
    const drag = dragging();
    if (!drag) return;
    setPanX((prev) => prev + e.clientX - drag.lastX);
    setPanY((prev) => prev + e.clientY - drag.lastY);
    setDragging({ lastX: e.clientX, lastY: e.clientY });
  };

  const handleUp = () => {
    setDragging(null);
    window.removeEventListener("mousemove", handleMove);
    window.removeEventListener("mouseup", handleUp);
  };

  const onPanStart = (e: MouseEvent) => {
    if (e.button !== 0) return;
    setDragging({ lastX: e.clientX, lastY: e.clientY });
    window.addEventListener("mousemove", handleMove);
    window.addEventListener("mouseup", handleUp);
  };

  onCleanup(() => {
    window.removeEventListener("mousemove", handleMove);
    window.removeEventListener("mouseup", handleUp);
  });

  const onWheel = (deltaY: number, anchorX: number, anchorY: number) => {
    const factor = deltaY < 0 ? ZOOM_FACTOR : 1 / ZOOM_FACTOR;
    const oldZoom = zoom();
    const newZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, oldZoom * factor));
    setPanX((prev) => anchorX - (anchorX - prev) * (newZoom / oldZoom));
    setPanY((prev) => anchorY - (anchorY - prev) * (newZoom / oldZoom));
    setZoom(newZoom);
  };

  return {
    panX,
    panY,
    zoom,
    isDragging: () => dragging() !== null,
    onPanStart,
    onWheel,
  };
}
