import React from 'react';

const map = {
  amber: ['245, 200, 105', 'var(--kn-amber)'],
  mint: ['125, 211, 192', 'var(--kn-mint)'],
  red: ['255, 107, 107', 'var(--kn-red)'],
  lilac: ['184, 165, 217', 'var(--kn-lilac)'],
};

export function Callout({ hue = 'amber', bar = true, children, style, ...rest }) {
  const [rgb, color] = map[hue];
  return (
    <div
      style={{
        padding: '8px 12px',
        background: `rgba(${rgb}, 0.1)`,
        border: bar ? 'none' : `1px solid rgba(${rgb}, 0.3)`,
        borderLeft: bar ? `3px solid ${color}` : `1px solid rgba(${rgb}, 0.3)`,
        borderRadius: 'var(--radius-sm)',
        color,
        ...style,
      }}
      {...rest}
    >
      {children}
    </div>
  );
}
