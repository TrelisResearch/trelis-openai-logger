-- migrate:up
CREATE TABLE IF NOT EXISTS llm_traces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    model VARCHAR(255),
    endpoint VARCHAR(255),
    input_messages JSONB DEFAULT '[]'::jsonb,
    raw_response JSONB,
    latency_ms FLOAT,
    status_code INTEGER,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    meta_data JSONB,
    error TEXT
);

-- migrate:down
DROP TABLE IF EXISTS llm_traces;
