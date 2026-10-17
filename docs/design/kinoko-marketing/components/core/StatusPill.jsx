import React from 'react';

export function StatusPill({ hue = 'mint', pulse = true, children, style, ...rest }) {
  const color = { mint: 'var(--kn-mint)', lilac: 'var(--kn-lilac)', amber: 'var(--kn-amber)', red: 'var(--kn-red)' }[hue];
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--space-2)',
        padding: '8px 16px',
        backgroundColor: 'rgba(26, 23, 37, 0.8)',
        border: '1px solid var(--kn-border)',
        borderRadius: 'var(--radius-pill)',
        boxShadow: 'var(--glow-mint-faint)',
        ...style,
      }}
      {...rest}
    >
      <span
        style={{
          width: 8, height: 8, borderRadius: '50%',
          backgroundColor: color,
          boxShadow: `0 0 10px ${color}`,
          animation: pulse ? 'kn-pulse-glow 2s ease-in-out infinite' : undefined,
          flexShrink: 0,
        }}
      />
      <span style={{ fontSize: 'var(--text-ui)', color: 'var(--kn-text-muted)' }}>{children}</span>
    </div>
  );
}
