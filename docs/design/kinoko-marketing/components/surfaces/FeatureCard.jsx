import React from 'react';
import { Card } from './Card.jsx';
import { Tag } from '../core/Tag.jsx';
import { MushroomIcon } from '../brand/MushroomIcon.jsx';

export function FeatureCard({ variant = 'sprout', hue = '#7DD3C0', title, description, comingSoon = false, compact = false, style, ...rest }) {
  return (
    <Card tone={comingSoon ? 'muted' : compact ? 'default' : 'lifted'} padding={compact ? 24 : 32} style={style} {...rest}>
      {comingSoon && (
        <Tag hue="amber" style={{ position: 'absolute', top: 12, right: 12 }}>Coming soon</Tag>
      )}
      {compact ? (
        <div style={{ marginBottom: 'var(--space-3)' }}>
          <MushroomIcon variant={variant} color={hue} size={36} />
        </div>
      ) : (
        <div
          style={{
            width: 56, height: 56, borderRadius: 'var(--radius-lg)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            marginBottom: 'var(--space-5)',
            backgroundColor: `${hue}15`,
            boxShadow: `0 0 25px ${hue}25`,
          }}
        >
          <MushroomIcon variant={variant} color={hue} size={36} />
        </div>
      )}
      <h3
        style={{
          fontFamily: 'var(--font-display)',
          fontSize: compact ? 'var(--text-tile-title)' : 'var(--text-card-title)',
          fontWeight: 'var(--weight-semibold)',
          color: 'var(--kn-text)',
          marginBottom: compact ? 'var(--space-2)' : 'var(--space-3)',
        }}
      >
        {title}
      </h3>
      <p style={{ color: 'var(--kn-text-muted)', fontSize: compact ? 'var(--text-ui)' : 'var(--text-base)', lineHeight: compact ? 'var(--leading-tight)' : 'var(--leading-body)', margin: 0 }}>
        {description}
      </p>
    </Card>
  );
}
