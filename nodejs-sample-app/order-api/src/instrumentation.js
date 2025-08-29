/**
 * AWS Distro for OpenTelemetry (ADOT) Configuration
 * 
 * This file provides additional configuration for ADOT auto-instrumentation,
 * specifically for Winston logs-to-traces correlation.
 * 
 * ADOT handles all the basic instrumentation automatically when started with:
 * --require @aws/aws-distro-opentelemetry-node-autoinstrumentation/register
 */

const { WinstonInstrumentation } = require('@opentelemetry/instrumentation-winston');
const { registerInstrumentations } = require('@opentelemetry/instrumentation');

// Register additional Winston instrumentation for enhanced logs-to-traces correlation
// ADOT already includes Winston instrumentation, but we can enhance it with custom logHook
registerInstrumentations({
    instrumentations: [
        new WinstonInstrumentation({
            // Enhanced logHook for better trace context injection
            logHook: (span, record) => {
                const spanContext = span.spanContext();
                if (spanContext && spanContext.traceId && spanContext.spanId) {
                    // Use the same field names as CloudWatch Application Signals expects
                    record.trace_id = spanContext.traceId;
                    record.span_id = spanContext.spanId;
                    record.trace_flags = spanContext.traceFlags;
                }
            },
        }),
    ],
});

console.log('ADOT enhanced Winston instrumentation configured for logs-to-traces correlation');
