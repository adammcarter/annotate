import React from 'react';
import marksData from './marks.json';

/** The role colours, read off Tokens.swift so the reel and the app agree. */
export const COLORS = {
  accent: 'rgb(124, 107, 255)',
  warn: 'rgb(255, 175, 56)',
  ok: 'rgb(61, 191, 131)',
  ink: 'rgb(244, 242, 239)',
  highlight: 'rgb(255, 228, 92)',
  // Not roles — the drawing tools take any #RRGGBB, and the reel uses a couple
  // to make the point that the palette is not four fixed colours.
  pink: 'rgb(244, 94, 160)',
  blue: 'rgb(74, 166, 255)',
};

type Stroke = {
  ribbon: number[][];
  arc: number[];
  centerline: number[][];
  opacity: number;
};

export type Mark = {
  tool: string;
  label?: string;
  target?: number[];
  at?: number[];
  strokes?: Stroke[];
  bands?: {
    d: string;
    lineWidth: number;
    length: number;
    start: number[];
    end: number[];
    streaks: {
      alongLength: number; acrossWidth: number;
      halfLength: number; halfWidth: number;
      strength: number; darkens: boolean;
    }[];
  }[];
  strokeWidth?: number;
  /** Wipe plan, straight from WipePlanner. */
  polyline?: number[][];
  band?: number;
  travel?: number;
  duration?: number;
  softness?: number;
};

export const MARKS = marksData.marks as Mark[];
export const TIMING = marksData.timing as Record<string, number>;

export const mark = (tool: string) => MARKS.find((m) => m.tool === tool)!;

/**
 * The ribbon, revealed along its own arc length.
 *
 * The exported polygon runs up the top edge for n points and back down the
 * bottom edge for n more, so a partial draw is not an approximation — it is the
 * same polygon truncated at the matching vertex on both edges, which keeps it
 * closed and correctly wound at every frame. Interpolating opacity instead
 * would fade the whole mark in at once and lose the thing that makes Annotate's
 * ink read as drawn rather than placed.
 */
export const Ribbon: React.FC<{
  stroke: Stroke;
  progress: number;
  color: string;
  opacity?: number;
}> = ({ stroke, progress, color, opacity = 1 }) => {
  const n = stroke.arc.length;
  if (n < 2) return null;

  let k = 1;
  while (k < n && stroke.arc[k] <= progress) k++;
  if (k < 2) return null;

  const top = stroke.ribbon.slice(0, k);
  const bottom = stroke.ribbon.slice(2 * n - k);
  const points = [...top, ...bottom];
  const d = points.map((p, i) => `${i === 0 ? 'M' : 'L'} ${p[0]} ${p[1]}`).join(' ') + ' Z';

  return <path d={d} fill={color} opacity={stroke.opacity * opacity} />;
};

/** Every pass of one mark, drawn together. */
export const PenMark: React.FC<{
  strokes: Stroke[];
  progress: number;
  color: string;
  opacity?: number;
}> = ({ strokes, progress, color, opacity }) => (
  <>
    {strokes.map((s, i) => (
      <Ribbon key={i} stroke={s} progress={progress} color={color} opacity={opacity} />
    ))}
  </>
);
