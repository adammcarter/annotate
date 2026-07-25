import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, Easing } from 'remotion';
import { COLORS, PenMark, mark } from './ink';

export const FPS = 30;

/**
 * The visible frame, cropped to the marks.
 *
 * Geometry is authored in an 800x450 design space because that is what
 * AnnotateCore was handed, but the marks only ever occupy a band through the
 * middle of it. Shipping the whole 16:9 canvas meant a README-width video whose
 * subject was half the frame and unreadable at that size. Cropping to the
 * content — rather than scaling the type up inside a mostly-empty frame — keeps
 * every mark the size AnnotateCore actually drew it.
 */
// Sized to the union of everything that ever draws — every mark's ribbon
// bounds, the band widths, the glyph boxes, and the closing card AFTER its
// transform — plus a uniform margin. Measured rather than guessed: eyeballing
// it clipped the closing loop's lead-in tail twice.
const VIEW = { x: 190, y: 110, w: 420, h: 200 };
const W = VIEW.w;
const H = VIEW.h;

/**
 * One tool per shot, each annotating its own NAME.
 *
 * "Loop" gets looped, "Underline" gets underlined. No invented interface is
 * needed to point at, and the mark and its meaning become the same object on
 * screen — there is nothing to misread about which part is the demonstration.
 *
 * The last shot is annotate_clear, which is a tool too, so the wipe is the
 * final demonstration rather than an outro. Then the call to action, drawn with
 * the reel's own pen.
 */
type Beat = {
  tool: string;
  word: string;
  color: string;
  page?: boolean;
  /**
   * Where on the canvas this shot sits.
   *
   * Deliberately somewhere different for each tool. Five shots all landing dead
   * centre is a slideshow — the eye settles and stops looking. Moving the work
   * around the frame makes each cut a small reorientation, which is what keeps
   * attention through a montage with no motion between shots.
   *
   * The closing card is the exception and sits centred: it is the payoff, and
   * the one moment the eye should not have to go looking.
   *
   * Offsets are measured from each shot's own content bounds — its marks AND
   * its word, which is a different width in every shot — not eyeballed.
   */
  dx: number;
  dy: number;
};

const BEATS: Beat[] = [
  { tool: 'annotate_circle', word: 'Loop', color: COLORS.pink, dx: -100, dy: -31 },
  { tool: 'annotate_underline', word: 'Underline', color: COLORS.ok, dx: 70.6, dy: 41 },
    // A translucent marker over a dark screen is olive, not yellow — which is
  // true of the product and of every real highlighter. So this shot puts its
  // word on a page, which is where a marker belongs and where the colour reads.
  { tool: 'annotate_highlight', word: 'Highlight', color: COLORS.highlight, page: true, dx: -69.5, dy: 52 },
  { tool: 'annotate_arrow', word: 'Point', color: COLORS.blue, dx: 109.4, dy: -29.4 },
];

/**
 * A mark takes about half a second on screen, which is right for a mark and far
 * too quick for a shot — at 30fps the earlier cut spent ten frames drawing and
 * the rest holding, so the eye only ever caught the finished line. The reel
 * slows the draw to give each tool its moment. It is the app's pacing stretched,
 * not different pacing: same curve, same order, same geometry.
 */
const SLOWDOWN = 1.75;
const DRAW: Record<string, number> = {
  annotate_circle: 0.45 * SLOWDOWN,
  annotate_underline: 0.34 * SLOWDOWN,
  annotate_arrow: 0.52 * SLOWDOWN,
  annotate_highlight: 0.38 * SLOWDOWN,
};

// Held long enough to land, short enough that the whole reel still works as a
// README GIF — the draw is where the time goes, not the pauses around it.
const WORD_IN = 0.24;
const BEFORE_MARK = 0.22;
const AFTER_MARK = 0.46;
const HANDOFF = 0.24;

const beatLength = (b: Beat) => WORD_IN + BEFORE_MARK + DRAW[b.tool] + AFTER_MARK + HANDOFF;
const STARTS = BEATS.reduce<number[]>((acc, b, i) => {
  acc.push(i === 0 ? 0.25 : acc[i - 1] + beatLength(BEATS[i - 1]));
  return acc;
}, []);

const CLEAR_AT = STARTS[STARTS.length - 1] + beatLength(BEATS[BEATS.length - 1]) - HANDOFF + 0.2;

/**
 * The wipe, on the app's own plan.
 *
 * Annotate does not sweep a bar across the screen. Its eraser follows a path
 * planned over WHERE THE INK IS — stacked right-to-left passes, a band wide,
 * with soft stamps marched along it. The plan comes out of WipePlanner in the
 * export, so the reel erases with the product's gesture rather than a generic
 * left-to-right gradient that merely finished at the same moment.
 *
 * Stretched by the same factor as the marks. The app's own sweep for this much
 * ink is 0.63s, which at 30fps is nineteen frames.
 */
const WIPE = mark('wipe');
const SWEEP = (WIPE.duration as number) * SLOWDOWN;
const CTA_AT = CLEAR_AT + SWEEP + 0.15;
export const DURATION = Math.round((CTA_AT + 4.6) * FPS);

const ease = Easing.bezier(0.22, 1, 0.36, 1);
const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const Word: React.FC<{ text: string; opacity: number; onPage?: boolean }> = ({ text, opacity, onPage }) => (
  <text x={400} y={216} fill={onPage ? '#26262c' : '#f4f2ef'} fontSize={44} textAnchor="middle" opacity={opacity}
    fontFamily="-apple-system, system-ui, sans-serif" fontWeight={600}>
    {text}
  </text>
);

/**
 * The marker, rebuilt from the app's own band + streak data.
 *
 * A single flat 19%-alpha stroke is invisible over white and muddy over dark.
 * That alpha is the BASE density, not the whole mark: the app rasterises
 * streaky deposits and lets the ink pool along the nib's edges, and it is that
 * structure, not the wash, that makes the colour read at all.
 */
const Highlighter: React.FC<{ bands: NonNullable<Mark['bands']>; progress: number }> = ({ bands, progress }) => (
  <>
    {bands.map((b, i) => {
      const [sx, sy] = b.start;
      const [ex, ey] = b.end;
      const angle = Math.atan2(ey - sy, ex - sx);
      const dx = Math.cos(angle);
      const dy = Math.sin(angle);
      const nx = -dy;
      const ny = dx;
      const half = b.lineWidth / 2;

      return (
        // A MASK, not a clipPath: clip paths use only the FILL geometry of
        // their children, so clipping to a stroked band clipped the whole mark
        // away and the highlight simply never appeared.
        <g key={i} mask={`url(#band${i})`}>
          <defs>
            <mask id={`band${i}`}>
              <path d={b.d} stroke="#fff" strokeWidth={b.lineWidth} strokeLinecap="round"
                fill="none" pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - progress} />
            </mask>
          </defs>

          <path d={b.d} stroke={COLORS.highlight} strokeOpacity={0.3}
            strokeWidth={b.lineWidth} strokeLinecap="round" fill="none"
            pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - progress} />

          {/* Ink pools where the nib's edges drag — the two rim traces. */}
          {[-1, 1].map((side) => (
            <path key={side} d={b.d} stroke={COLORS.highlight} strokeOpacity={0.2}
              strokeWidth={b.lineWidth * 0.22} strokeLinecap="round" fill="none"
              transform={`translate(${nx * side * half * 0.86} ${ny * side * half * 0.86})`}
              pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - progress} />
          ))}

          {b.streaks.map((s, j) => {
            const cx = sx + dx * s.alongLength + nx * s.acrossWidth;
            const cy = sy + dy * s.alongLength + ny * s.acrossWidth;
            return (
              <ellipse key={j} cx={cx} cy={cy} rx={s.halfLength} ry={s.halfWidth}
                transform={`rotate(${(angle * 180) / Math.PI} ${cx} ${cy})`}
                fill={COLORS.highlight} fillOpacity={(s.darkens ? 0.32 : 0.12) * s.strength} />
            );
          })}
        </g>
      );
    })}
  </>
);

type Mark = ReturnType<typeof mark>;

const Shot: React.FC<{ beat: Beat; t: number; opacity: number }> = ({ beat, t, opacity }) => {
  const m = mark(beat.tool);
  const wordT = interpolate(t, [0, WORD_IN], [0, 1], { ...clamp, easing: ease });
  const markT = t - (WORD_IN + BEFORE_MARK);
  const p = interpolate(markT, [0, DRAW[beat.tool]], [0, 1], { ...clamp, easing: Easing.bezier(0.35, 0, 0.2, 1) });

  return (
    <g opacity={opacity} transform={`translate(${beat.dx} ${beat.dy})`}>
      <Word text={beat.word} opacity={wordT} onPage={beat.page} />
      {beat.tool === 'annotate_highlight' ? (
        <Highlighter bands={m.bands!} progress={p} />
      ) : (
        <PenMark strokes={m.strokes!} progress={p} color={beat.color} />
      )}
    </g>
  );
};

// The wipe was planned over the last shot's ink in its ORIGINAL position, so it
// carries that shot's centring nudge too — otherwise the eraser sweeps where the
// marks used to be.
const LAST = BEATS[BEATS.length - 1];
const ERASE_SHIFT = `translate(${LAST.dx} ${LAST.dy})`;

const WIPE_POINTS = WIPE.polyline as number[][];
const WIPE_ARC = (() => {
  const acc = [0];
  let total = 0;
  for (let i = 1; i < WIPE_POINTS.length; i++) {
    total += Math.hypot(
      WIPE_POINTS[i][0] - WIPE_POINTS[i - 1][0],
      WIPE_POINTS[i][1] - WIPE_POINTS[i - 1][1],
    );
    acc.push(total);
  }
  return { acc, total };
})();

/** The planned path, drawn as far as the eraser has travelled. */
const eraserPath = (progress: number) => {
  const want = WIPE_ARC.total * Math.min(Math.max(progress, 0), 1);
  let k = 1;
  while (k < WIPE_POINTS.length && WIPE_ARC.acc[k] <= want) k++;
  return WIPE_POINTS.slice(0, Math.max(k, 2))
    .map((p, i) => `${i === 0 ? 'M' : 'L'} ${p[0]} ${p[1]}`)
    .join(' ');
};

/** Where the eraser is right now. */
const pointAt = (progress: number) => {
  const want = WIPE_ARC.total * Math.min(Math.max(progress, 0), 1);
  let k = 1;
  while (k < WIPE_POINTS.length && WIPE_ARC.acc[k] <= want) k++;
  const p = WIPE_POINTS[Math.min(k, WIPE_POINTS.length - 1)];
  return { x: p[0], y: p[1] };
};

export const Tools: React.FC = () => {
  const frame = useCurrentFrame();
  const time = frame / FPS;

  let index = 0;
  for (let i = 0; i < BEATS.length; i++) if (time >= STARTS[i]) index = i;
  const beat = BEATS[index];
  const local = time - STARTS[index];

  const clearing = time >= CLEAR_AT;
  const cta = time >= CTA_AT;

  // Each shot fades out as the next arrives — except the last, which stays up
  // for the wipe to erase.
  const isLast = index === BEATS.length - 1;
  const handoff = isLast
    ? 1
    : interpolate(local, [beatLength(beat) - HANDOFF, beatLength(beat) - 0.04], [1, 0], clamp);
  const present = Math.min(interpolate(local, [0, 0.2], [0, 1], { ...clamp, easing: ease }), handoff);

  const sweep = interpolate(time, [CLEAR_AT, CLEAR_AT + SWEEP], [0, 1], {
    ...clamp, easing: Easing.bezier(0.4, 0, 0.3, 1),
  });
  const erased = eraserPath(sweep);
  const head = pointAt(sweep);
  // The fade starts 30% before the sweep ends — the same overlap the app uses,
  // so the two read as one gesture rather than two events.
  const fadeStart = CLEAR_AT + SWEEP * 0.7;
  const fade = interpolate(time, [fadeStart, fadeStart + 0.56], [1, 0], clamp);

  const ctaT = time - CTA_AT;
  const ctaWord = interpolate(ctaT, [0, 0.35], [0, 1], { ...clamp, easing: ease });
  const ctaLoop = interpolate(ctaT, [0.5, 0.5 + 0.45 * SLOWDOWN], [0, 1], { ...clamp, easing: ease });
  const ctaArrow = interpolate(ctaT, [1.9, 1.9 + 0.52 * SLOWDOWN], [0, 1], { ...clamp, easing: ease });

  return (
    <AbsoluteFill style={{ backgroundColor: '#000' }}>
      <svg viewBox={`${VIEW.x} ${VIEW.y} ${VIEW.w} ${VIEW.h}`} width="100%" height="100%">
        <defs>
          {/* Softness is the stamp's own rim in the app; here it is the same
              width of blur on the swath's edge, which is what those overlapping
              soft stamps add up to. */}
          <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
            <feGaussianBlur stdDeviation={(WIPE.softness as number) / 3.2} />
          </filter>
          <mask id="erased">
            <rect x={VIEW.x} y={VIEW.y} width={VIEW.w} height={VIEW.h} fill="#fff" />
            {clearing ? (
              <path d={erased} transform={ERASE_SHIFT} stroke="#000" strokeWidth={WIPE.band as number}
                strokeLinecap="round" strokeLinejoin="round" fill="none" filter="url(#soft)" />
            ) : null}
          </mask>
          <radialGradient id="smudge">
            <stop offset="0" stopColor="#fff" stopOpacity="0.17" />
            <stop offset="1" stopColor="#fff" stopOpacity="0" />
          </radialGradient>
        </defs>

        <rect x={VIEW.x} y={VIEW.y} width={VIEW.w} height={VIEW.h}
          fill={beat.page && !clearing && !cta ? '#f4f2ef' : '#000'} />

        {cta ? null : (
          <g mask="url(#erased)" opacity={clearing ? fade : 1}>
            <Shot beat={beat} t={local} opacity={clearing ? 1 : present} />
          </g>
        )}

        {/* The eraser itself, riding the head of its own path. */}
        {clearing && !cta && sweep > 0 && sweep < 1 ? (
          <circle cx={head.x + LAST.dx} cy={head.y + LAST.dy}
            r={(WIPE.band as number) * 0.95} fill="url(#smudge)" />
        ) : null}

        {cta ? (
          // The closing card is a loop stacked on a downward arrow, so it is
          // taller and wider than any word shot. Left at full size it set the
          // frame for everything else, and every other shot paid for it in
          // empty space — so it is scaled to the frame rather than the frame to
          // it. Scaled about the card's own centre so the loop stays around the
          // words and the arrow stays under them.
          <g transform="translate(-0.2 3)">
            <text x={400} y={214} fill="#f4f2ef" fontSize={40} textAnchor="middle" opacity={ctaWord}
              fontFamily="-apple-system, system-ui, sans-serif" fontWeight={600}
              transform={`translate(0 ${(1 - ctaWord) * 6})`}>Install now.</text>
            <PenMark strokes={mark('cta_loop').strokes!} progress={ctaLoop} color={COLORS.accent} />
            <PenMark strokes={mark('cta_arrow').strokes!} progress={ctaArrow} color={COLORS.accent} />
          </g>
        ) : null}

      </svg>
    </AbsoluteFill>
  );
};
