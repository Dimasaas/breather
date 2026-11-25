# frozen_string_literal: true

require "test_helper"
require "apoio"

class FreioTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
  end

  def novo(**opcoes)
    Freio.new(base: 2, teto: 30, fator: 2, jitter: 0,
              relogio: @rel.relogio, dormir: @rel.sono, **opcoes)
  end

  def test_sem_pausa_aguardar_nao_espera
    freio = novo
    refute freio.aguardar!
    assert_empty @rel.sonos
    refute freio.pausado?
  end

  def test_acionar_abre_pausa_pela_base
    freio = novo
    assert_in_delta 2.0, freio.acionar!("503"), 1e-9
    assert freio.pausado?
    assert_in_delta 2.0, freio.restante, 1e-9
  end

  def test_aguardar_dorme_ate_o_fim_da_pausa
    freio = novo
    freio.acionar!
    assert freio.aguardar!
    assert_in_delta 2.0, @rel.agora, 1e-9
    refute freio.pausado?
  end

  def test_aguardar_dorme_em_fatias
    freio = novo(fatia: 0.5)
    freio.acionar!
    freio.aguardar!
    assert_equal [0.5] * 4, @rel.sonos
  end

  def test_acionar_durante_pausa_nao_escala
    freio = novo
    freio.acionar!
    assert_nil freio.acionar!("outro 503 da mesma janela")
    assert_equal 1, freio.pausas
    assert_equal 1, freio.seguidas
  end

  def test_backoff_exponencial_entre_janelas_seguidas
    freio = novo
    duracoes = 3.times.map do
      d = freio.acionar!
      freio.aguardar!
      d
    end
    assert_equal [2.0, 4.0, 8.0], duracoes
  end

  def test_sucesso_zera_o_backoff
    freio = novo
    2.times do
      freio.acionar!
      freio.aguardar!
    end
    freio.sucesso!
    assert_in_delta 2.0, freio.acionar!, 1e-9
  end

  def test_sucesso_durante_pausa_nao_zera
    freio = novo
    freio.acionar!
    freio.sucesso!
    assert_equal 1, freio.seguidas
  end

  def test_liberar_encerra_a_pausa_e_zera
    freio = novo
    freio.acionar!
    freio.liberar!
    refute freio.pausado?
    assert_equal 0, freio.seguidas
    refute freio.aguardar!
  end

  def test_espera_do_servidor_vira_piso
    freio = novo
    assert_in_delta 10.0, freio.acionar!("503", espera: 10), 1e-9
  end

  def test_espera_menor_que_a_base_nao_encurta
    freio = novo
    assert_in_delta 2.0, freio.acionar!("503", espera: 0.5), 1e-9
  end

  def test_ao_acionar_recebe_motivo_e_duracao
    visto = []
    freio = novo(ao_acionar: ->(motivo, d) { visto << [motivo, d] })
    freio.acionar!("HTTP 503")
    freio.acionar!("repetido")
    assert_equal [["HTTP 503", 2.0]], visto
  end

  def test_parametros_invalidos
    assert_raises(ArgumentError) { Freio.new(base: 0) }
    assert_raises(ArgumentError) { Freio.new(base: 5, teto: 1) }
    assert_raises(ArgumentError) { Freio.new(fator: 0.5) }
    assert_raises(ArgumentError) { Freio.new(jitter: 1.5) }
    assert_raises(ArgumentError) { Freio.new(fatia: 0) }
  end
end
