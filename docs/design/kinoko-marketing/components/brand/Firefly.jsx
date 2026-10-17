import React from 'react';

export function Firefly({ color = '#7DD3C0', left = '50%', top = '50%', size = 8, duration = '4s', delay = '0s' }) {
  return (
    <div style={{ position: 'absolute', left, top, pointerEvents: 'none', animation: `kn-twinkle ${duration} ease-in-out infinite`, animationDelay: delay }}>
      <div style={{ width: size, height: size, borderRadius: '50%', backgroundColor: color, boxShadow: `0 0 12px 4px ${color}`, opacity: 0.8 }} />
    </div>
  );
}
