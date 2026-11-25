# frozen_string_literal: true

require_relative "lib/breather/version"

Gem::Specification.new do |s|
  s.name          = "breather"
  s.version       = Breather::VERSION
  s.authors       = ["João Victor Diamantino Cardoso"]
  s.summary       = "Freio global cooperativo para APIs que devolvem 503 em janelas."
  s.description   = "No primeiro 503 todas as threads que compartilham o Breather pausam, com " \
                    "backoff exponencial, teto e jitter. Só operações idempotentes são refeitas."
  s.homepage      = "https://github.com/Dimasaas/breather"
  s.license       = "PolyForm-Noncommercial-1.0.0"
  s.required_ruby_version = ">= 3.2"
  s.files         = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  s.require_paths = ["lib"]
  s.metadata["rubygems_mfa_required"] = "true"
end
