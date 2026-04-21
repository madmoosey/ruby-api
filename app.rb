require "json"
require "sinatra"
require "sequel"
require "pg"
require "openai"

DATABASE_URL = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/contentdb")
OPENAI_MODEL = ENV.fetch("OPENAI_MODEL", "gpt-5.2")
OPENAI_API_KEY = ENV.fetch("OPENAI_API_KEY")

DB = Sequel.connect(DATABASE_URL, test: true)

unless DB.table_exists?(:content_ideas)
  DB.create_table :content_ideas do
    primary_key :id
    String :topic, null: false, size: 255
    String :audience, size: 255
    String :tone, size: 100
    Text :ideas_json, null: false
    DateTime :created_at, null: false
    DateTime :updated_at, null: false
    index :topic
  end
end

content_ideas = DB[:content_ideas]

OPENAI_CLIENT = OpenAI::Client.new(api_key: OPENAI_API_KEY)

class App < Sinatra::Base
  set :show_exceptions, false

  before do
    content_type :json
  end

  helpers do
    def dataset
      DB[:content_ideas]
    end

    def json_params
      request.body.rewind
      raw = request.body.read
      return {} if raw.nil? || raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      halt 400, { error: "Invalid JSON body" }.to_json
    end

    def parse_ideas_output(response)
      text =
        if response.respond_to?(:output_text) && response.output_text
          response.output_text
        elsif response.is_a?(Hash) && response["output_text"]
          response["output_text"]
        else
          nil
        end

      halt 500, { error: "OpenAI response missing output_text" }.to_json if text.nil? || text.strip.empty?

      parsed = JSON.parse(text)
      ideas = parsed["ideas"]

      unless ideas.is_a?(Array) && ideas.all? { |v| v.is_a?(String) }
        halt 500, { error: "Model output did not match expected JSON schema" }.to_json
      end

      ideas
    rescue JSON::ParserError
      halt 500, { error: "Failed to parse model output as JSON", raw_output: text }.to_json
    end

    def generate_content_ideas(topic:, audience:, tone:)
      audience_text = audience.to_s.strip.empty? ? "a general audience" : audience
      tone_text = tone.to_s.strip.empty? ? "clear and engaging" : tone

      prompt = <<~PROMPT
        Generate 10 strong content ideas.

        Topic: #{topic}
        Target audience: #{audience_text}
        Tone: #{tone_text}

        Return valid JSON only in this exact shape:
        {
          "ideas": [
            "idea 1",
            "idea 2"
          ]
        }

        Rules:
        - Each idea should be specific enough to be immediately useful.
        - Avoid duplicates.
        - Keep each idea to one sentence.
        - No markdown.
      PROMPT

      response = OPENAI_CLIENT.responses.create(
        model: OPENAI_MODEL,
        input: prompt
      )

      parse_ideas_output(response)
    end

    def refine_content_ideas(topic:, audience:, tone:, existing_ideas:, refinement_request:)
      audience_text = audience.to_s.strip.empty? ? "a general audience" : audience
      tone_text = tone.to_s.strip.empty? ? "clear and engaging" : tone
      existing_ideas_text = existing_ideas.map { |idea| "- #{idea}" }.join("\n")

      prompt = <<~PROMPT
        Refine an existing set of content ideas.

        Topic: #{topic}
        Target audience: #{audience_text}
        Tone: #{tone_text}

        Existing ideas:
        #{existing_ideas_text}

        Refinement request:
        #{refinement_request}

        Return valid JSON only in this exact shape:
        {
          "ideas": [
            "refined idea 1",
            "refined idea 2"
          ]
        }

        Rules:
        - Return 10 refined ideas.
        - Preserve the original topic and audience alignment.
        - Apply the refinement request directly.
        - Avoid duplicates.
        - Keep each idea to one sentence.
        - No markdown.
      PROMPT

      response = OPENAI_CLIENT.responses.create(
        model: OPENAI_MODEL,
        input: prompt
      )

      parse_ideas_output(response)
    end

    def serialize_row(row)
      {
        id: row[:id],
        topic: row[:topic],
        audience: row[:audience],
        tone: row[:tone],
        ideas: JSON.parse(row[:ideas_json]),
        created_at: row[:created_at],
        updated_at: row[:updated_at]
      }
    end
  end

  get "/health" do
    { status: "ok" }.to_json
  end

  post "/ideas" do
    payload = json_params

    topic = payload["topic"].to_s.strip
    audience = payload["audience"]&.to_s&.strip
    tone = payload["tone"]&.to_s&.strip

    halt 422, { error: "topic is required" }.to_json if topic.empty?

    ideas = generate_content_ideas(topic: topic, audience: audience, tone: tone)
    now = Time.now

    id = dataset.insert(
      topic: topic,
      audience: audience,
      tone: tone,
      ideas_json: JSON.dump(ideas),
      created_at: now,
      updated_at: now
    )

    row = dataset.where(id: id).first
    status 201
    serialize_row(row).to_json
  end

  get "/ideas" do
    rows = dataset.order(Sequel.desc(:id)).all
    rows.map { |row| serialize_row(row) }.to_json
  end

  get "/ideas/:idea_id" do
    row = dataset.where(id: params[:idea_id].to_i).first
    halt 404, { error: "Idea set not found" }.to_json unless row

    serialize_row(row).to_json
  end

  post "/ideas/:idea_id/refine" do
    row = dataset.where(id: params[:idea_id].to_i).first
    halt 404, { error: "Idea set not found" }.to_json unless row

    payload = json_params
    refinement_request = payload["refinement_request"].to_s.strip
    halt 422, { error: "refinement_request is required" }.to_json if refinement_request.empty?

    existing_ideas = JSON.parse(row[:ideas_json])

    refined_ideas = refine_content_ideas(
      topic: row[:topic],
      audience: row[:audience],
      tone: row[:tone],
      existing_ideas: existing_ideas,
      refinement_request: refinement_request
    )

    now = Time.now

    dataset.where(id: row[:id]).update(
      ideas_json: JSON.dump(refined_ideas),
      updated_at: now
    )

    updated = dataset.where(id: row[:id]).first
    serialize_row(updated).to_json
  end

  error Sequel::DatabaseError do
    status 500
    { error: "Database error", detail: env["sinatra.error"].message }.to_json
  end

  error KeyError do
    status 500
    { error: "Missing required environment variable", detail: env["sinatra.error"].message }.to_json
  end

  error StandardError do
    status 500
    { error: "Server error", detail: env["sinatra.error"].message }.to_json
  end
end

run App