import React from 'react';

const marks = {
  ok: { glyph: '✓', color: 'var(--kn-mint)' },
  running: { glyph: '⟳', color: 'var(--kn-amber)' },
  fail: { glyph: '✗', color: 'var(--kn-red)' },
};

export function TerminalLine({ speaker, tone = 'plain', label, note, indent = false, children, style, ...rest }) {
  const speakerColor = { you: 'var(--kn-mint)', pm: 'var(--kn-lilac)', agent: 'var(--kn-mint-light)' }[speaker];

  if (speaker) {
    return (
      <div style={{ display: 'flex', gap: 'var(--space-3)', marginBottom: 'var(--space-3)', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-ui)', ...style }} {...rest}>
        <span style={{ color: speakerColor }}>{speaker}:</span>
        <span style={{ color: speaker === 'you' ? 'var(--kn-cream)' : 'rgba(229, 223, 213, 0.7)' }}>{children}</span>
      </div>
    );
  }

  const mark = marks[tone];
  return (
    <div
      style={{
        display: 'flex', alignItems: 'center', gap: 'var(--space-2)',
        paddingLeft: indent ? 48 : 0,
        fontFamily: 'var(--font-mono)', fontSize: 'var(--text-ui)',
        ...style,
      }}
      {...rest}
    >
      {mark && (
        <span style={{ color: mark.color, textShadow: `0 0 10px ${mark.color === 'var(--kn-mint)' ? '#7DD3C0' : mark.color === 'var(--kn-amber)' ? '#F5C869' : '#FF6B6B'}`, animation: tone === 'running' ? 'kn-pulse-glow 1.5s ease-in-out infinite' : undefined }}>
          {mark.glyph}
        </span>
      )}
      {label && <span style={{ color: tone === 'running' ? 'rgba(245, 200, 105, 0.8)' : 'var(--kn-mint-light)' }}>{label}</span>}
      {note && <span style={{ color: 'var(--kn-text-faint)' }}>— {note}</span>}
      {children}
    </div>
  );
}
