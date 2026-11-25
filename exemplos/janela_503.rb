#!/usr/bin/env ruby
# frozen_string_literal: true

# Simula uma API que fica fora do ar (503) por uma janela e compara duas
# estratégias com os mesmos workers:
#
#   ANTES  - cada thread tem a sua retentativa (3 tentativas seguidas, sem espera)
#   DEPOIS - todas as threads compartilham um Breather
#
# Rode:  ruby exemplos/janela_503.rb
#
# A escala é reduzida (janela de ~1 s) para o exemplo terminar rápido; a
# proporção é a mesma de uma janela de ~30 s com pausas de dezenas de segundos.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "breather"

TRABALHADORES = 8
CONSULTAS_POR_TRABALHADOR = 25
JANELA_INICIO = 0.3   # s depois do começo
JANELA_FIM    = 1.3
LATENCIA      = 0.01  # s por requisição que chega ao servidor

# Servidor falso: conta tudo o que chega, inclusive o que recebe de 503.
class ApiFalsa
  attr_reader :recebidas, :recusadas

  def initialize
    @inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @mutex = Mutex.new
    @recebidas = 0
    @recusadas = 0
  end

  def consultar
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @inicio
    fora = t >= JANELA_INICIO && t < JANELA_FIM
    @mutex.synchronize do
      @recebidas += 1
      @recusadas += 1 if fora
    end
    sleep LATENCIA
    raise Breather::Indisponivel, "503" if fora

    :ok
  end
end

def rodar(rotulo)
  api = ApiFalsa.new
  inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  perdidas = 0
  trava = Mutex.new

  threads = Array.new(TRABALHADORES) do
    Thread.new do
      CONSULTAS_POR_TRABALHADOR.times do
        begin
          yield api
        rescue Breather::Indisponivel
          trava.synchronize { perdidas += 1 }
        end
      end
    end
  end
  threads.each(&:join)

  duracao = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inicio
  { rotulo: rotulo, api: api, perdidas: perdidas, duracao: duracao }
end

# ANTES: retentativa por thread, imediata.
antes = rodar("antes (retentativa por thread)") do |api|
  tentativas = 0
  begin
    tentativas += 1
    api.consultar
  rescue Breather::Indisponivel
    retry if tentativas < 3
    raise
  end
end

# DEPOIS: um breather compartilhado.
breather = Breather.new(base: 0.4, teto: 2.0, fator: 2, jitter: 0.1, fatia: 0.05)
depois = rodar("depois (Breather compartilhado)") do |api|
  Breather.executar(breather, idempotente: true, tentativas: 6) { api.consultar }
end

total = TRABALHADORES * CONSULTAS_POR_TRABALHADOR
puts "Consultas pedidas: #{total} (#{TRABALHADORES} threads x #{CONSULTAS_POR_TRABALHADOR})"
puts "Janela de 503: #{JANELA_FIM - JANELA_INICIO} s\n\n"
puts format("%-34s %10s %10s %10s %8s", "", "requisições", "503 levados", "perdidas", "tempo")
[antes, depois].each do |r|
  puts format("%-34s %11d %11d %10d %7.2fs",
              r[:rotulo], r[:api].recebidas, r[:api].recusadas, r[:perdidas], r[:duracao])
end
puts "\nPausas abertas pelo Breather: #{breather.pausas}"
puts format("503 evitados: %.0f%%", 100.0 * (1 - depois[:api].recusadas.to_f / [antes[:api].recusadas, 1].max))
