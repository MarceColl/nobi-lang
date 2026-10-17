import React from 'react';

export function Wordmark({ size = 28, color = 'var(--kn-cream)', style, ...rest }) {
  return (
    <span
      style={{
        fontFamily: 'var(--font-display)',
        fontSize: size,
        fontWeight: size >= 24 ? 'var(--weight-bold)' : 'var(--weight-semibold)',
        color,
        letterSpacing: '-0.01em',
        lineHeight: 1,
        ...style,
      }}
      {...rest}
    >
      kinoko
    </span>
  );
}
