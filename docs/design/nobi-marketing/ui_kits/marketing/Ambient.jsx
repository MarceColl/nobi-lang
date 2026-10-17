import React from 'react';
import { Firefly } from '../../components/brand/Firefly.jsx';

/* The page ground: three radial washes, a starfield, and drifting motes.
   Constants are the source's (App.tsx 493-512) — note that stars are confined
   to the TOP HALF of the page, which is what makes the ground read as a sky. */
const STAR_COUNT = 30;
const MOTE_COUNT = 35;
const MOTE_HUES = ['#7DD3C0', '#F5C869', '#B8A5D9', '#9FEDD7'];

export function Ambient() {
  const stars = React.useMemo(() => Array.from({ length: STAR_COUNT }, (_, i) => ({
    id: i,
    left: `${Math.random() * 100}%`,
    top: `${Math.random() * 50}%`,
    size: Math.random() * 2 + 1,
    opacity: Math.random() * 0.4 + 0.1,
  })), []);

  const motes = React.useMemo(() => Array.from({ length: MOTE_COUNT }, (_, i) => ({
    id: i,
    color: MOTE_HUES[Math.floor(Math.random() * MOTE_HUES.length)],
    left: `${Math.random() * 100}%`,
    top: `${Math.random() * 100}%`,
    duration: `${2 + Math.random() * 4}s`,
    delay: `${Math.random() * 5}s`,
  })), []);

  return (
    <React.Fragment>
      <div style={{ position: 'absolute', inset: 0, background: 'var(--wash-page)', pointerEvents: 'none' }} />
      <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
        {stars.map(s => (
          <div key={s.id} style={{ position: 'absolute', left: s.left, top: s.top, width: s.size, height: s.size, background: '#fff', borderRadius: '50%', opacity: s.opacity }} />
        ))}
        {motes.map(m => <Firefly key={m.id} {...m} />)}
      </div>
    </React.Fragment>
  );
}
