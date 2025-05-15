-- migrate:up
CREATE TABLE llm_traces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    model VARCHAR(255),
    endpoint VARCHAR(255),
    prompt JSONB,
    response JSONB,
    latency_ms FLOAT,
    status_code INTEGER,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    meta_data JSONB,
    error TEXT
);

-- migrate:down
DROP TABLE llm_traces;
