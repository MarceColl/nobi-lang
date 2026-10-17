import React from 'react';

export function TraceChip({ children, style, ...rest }) {
  return (
    <span
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 'var(--space-1)',
        padding: '2px 6px',
        background: 'rgba(159, 237, 215, 0.15)',
        border: '1px solid rgba(159, 237, 215, 0.3)',
        borderRadius: 'var(--radius-xs)',
        fontSize: 'var(--text-nano)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--kn-mint-light)',
        cursor: 'pointer',
        position: 'relative',
        ...style,
      }}
      {...rest}
    >
      <span style={{ opacity: 0.7 }}>▸</span>
      {children}
    </span>
  );
}
