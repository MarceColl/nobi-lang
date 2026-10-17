import React from 'react';

const hues = {
  mint: 'var(--kn-mint)',
  lilac: 'var(--kn-lilac)',
  amber: 'var(--kn-amber)',
  red: 'var(--kn-red)',
  mintLight: 'var(--kn-mint-light)',
};
const rgb = {
  mint: '125, 211, 192',
  lilac: '184, 165, 217',
  amber: '245, 200, 105',
  red: '255, 107, 107',
  mintLight: '159, 237, 215',
};

export function Tag({ hue = 'amber', size = 'sm', children, style, ...rest }) {
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--space-1)',
        padding: size === 'xs' ? '2px 6px' : '4px 8px',
        background: `rgba(${rgb[hue]}, 0.15)`,
        border: `1px solid rgba(${rgb[hue]}, 0.3)`,
        borderRadius: 'var(--radius-sm)',
        fontSize: size === 'xs' ? 'var(--text-nano)' : 'var(--text-micro)',
        fontWeight: 'var(--weight-semibold)',
        color: hues[hue],
        lineHeight: 1.4,
        ...style,
      }}
      {...rest}
    >
      {children}
    </span>
  );
}
