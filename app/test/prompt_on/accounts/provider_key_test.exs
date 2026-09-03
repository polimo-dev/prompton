defmodule PromptOn.Accounts.ProviderKeyTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.ProviderKey

  @secret "sk-or-v1-0123456789abcdef0123456789abcdef4Xa2"

  setup do
    owner = user_fixture()
    org = organization_for(owner)
    %{owner: owner, org: org}
  end

  defp member_scope(owner), do: [actor: owner]

  describe "register / rotate / revoke" do
    test "register stores a masked hint and a decryptable secret", %{org: org, owner: owner} do
      assert {:ok, key} =
               Accounts.register_provider_key(
                 %{
                   organization_id: org.id,
                   provider: :openrouter,
                   label: "default",
                   secret: @secret
                 },
                 member_scope(owner)
               )

      assert key.organization_id == org.id
      assert key.provider == :openrouter
      assert key.label == "default"
      assert key.secret_hint == "sk-or-v1-••••4Xa2"
      assert is_nil(key.revoked_at)
      assert is_nil(key.last_used_at)
      # The default load does not decrypt
      assert %Ash.NotLoaded{} = key.secret
    end

    test "label defaults to \"default\"", %{org: org, owner: owner} do
      assert {:ok, key} =
               Accounts.register_provider_key(
                 %{
                   organization_id: org.id,
                   provider: :openrouter,
                   secret: "sk-or-v1-0123456789abcdef"
                 },
                 member_scope(owner)
               )

      assert key.label == "default"
      assert key.secret_hint == "sk-or-v1-••••cdef"
    end

    test "register rejects a blank secret and any provider but openrouter", %{
      org: org,
      owner: owner
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.register_provider_key(
                 %{organization_id: org.id, provider: :openrouter, secret: "   "},
                 member_scope(owner)
               )

      # BYOK is OpenRouter only (2026-09-01): former providers are refused just like unknown names.
      for provider <- [:openai, :anthropic, :groq, :google, :cohere] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Accounts.register_provider_key(
                   %{organization_id: org.id, provider: provider, secret: @secret},
                   member_scope(owner)
                 ),
               "expected #{provider} to be rejected"
      end
    end

    test "providers/0 is openrouter only" do
      assert ProviderKey.providers() == [:openrouter]
    end

    test "rotate replaces the secret and recomputes the hint", %{org: org, owner: owner} do
      key = provider_key_fixture(org, secret: @secret)
      assert key.secret_hint == "sk-or-v1-••••4Xa2"

      rotated = "sk-or-v1-ffffffffffffffffffffffffffffffffZZ99"

      assert {:ok, key} =
               Accounts.rotate_provider_key(key, %{secret: rotated}, member_scope(owner))

      assert key.secret_hint == "sk-or-v1-••••ZZ99"

      assert Ash.load!(key, [:secret], member_scope(owner)).secret == rotated
    end

    test "rotate refuses a blank secret", %{org: org, owner: owner} do
      key = provider_key_fixture(org, secret: @secret)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.rotate_provider_key(key, %{secret: ""}, member_scope(owner))

      assert Ash.load!(key, [:secret], member_scope(owner)).secret == @secret
    end

    test "revoke is soft and drops the key from :active", %{org: org, owner: owner} do
      key = provider_key_fixture(org)

      assert {:ok, [_]} = Accounts.list_provider_keys(org.id, member_scope(owner))
      assert {:ok, revoked} = Accounts.revoke_provider_key(key, member_scope(owner))
      assert %DateTime{} = revoked.revoked_at
      assert {:ok, []} = Accounts.list_provider_keys(org.id, member_scope(owner))
      # The record itself remains (audit trail)
      assert {:ok, [_]} = Ash.read(ProviderKey, actor: owner)
    end

    test "touch_last_used stamps last_used_at", %{org: org, owner: owner} do
      key = provider_key_fixture(org)
      assert is_nil(key.last_used_at)

      assert {:ok, touched} = Accounts.touch_provider_key(key, %{}, member_scope(owner))
      assert %DateTime{} = touched.last_used_at
    end
  end

  describe "encryption" do
    test "the raw column holds ciphertext, load: [:secret] decrypts", %{org: org, owner: owner} do
      key = provider_key_fixture(org, secret: @secret)

      %{rows: [[encrypted]]} =
        Ecto.Adapters.SQL.query!(
          PromptOn.Repo,
          "SELECT encrypted_secret FROM provider_keys WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )

      assert is_binary(encrypted)
      refute encrypted =~ @secret
      refute encrypted =~ "0123456789abcdef"

      # base64(term_to_binary → AES-GCM)
      assert encrypted
             |> Base.decode64!()
             |> PromptOn.Vault.decrypt!()
             |> :erlang.binary_to_term() == @secret

      assert Ash.load!(key, [:secret], member_scope(owner)).secret == @secret
    end

    test "secret_hint stays plain text (no decryption needed to display it)", %{org: org} do
      key = provider_key_fixture(org, secret: @secret)

      %{rows: [[hint]]} =
        Ecto.Adapters.SQL.query!(
          PromptOn.Repo,
          "SELECT secret_hint FROM provider_keys WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )

      assert hint == "sk-or-v1-••••4Xa2"
    end
  end

  describe "policies" do
    test "an organization member may read and register", %{org: org, owner: owner} do
      assert {:ok, _key} =
               Accounts.register_provider_key(
                 %{organization_id: org.id, provider: :openrouter, secret: @secret},
                 member_scope(owner)
               )

      assert {:ok, [_]} = Accounts.list_provider_keys(org.id, member_scope(owner))
    end

    test "a member of another organization sees nothing and cannot register", %{org: org} do
      _key = provider_key_fixture(org)
      # A member of their own personal organization, but not of this one
      other = user_fixture()
      _other_org = organization_for(other)

      assert {:ok, []} = Accounts.list_provider_keys(org.id, actor: other)
      assert {:ok, nil} = Accounts.active_provider_key(org.id, :openrouter, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.register_provider_key(
                 %{
                   organization_id: org.id,
                   provider: :openrouter,
                   label: "stranger",
                   secret: @secret
                 },
                 actor: other
               )
    end

    test "an ApiKey actor never sees or writes provider keys", %{org: org, owner: owner} do
      key = provider_key_fixture(org)
      project = project_fixture(%{user: owner, organization: org})
      {api_key, _raw} = api_key_fixture(project)

      # Reads become an empty result via `no_filter_static_forbidden_reads?: false`
      assert {:ok, []} = Accounts.list_provider_keys(org.id, actor: api_key)
      assert {:ok, nil} = Accounts.active_provider_key(org.id, :openrouter, actor: api_key)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.register_provider_key(
                 %{organization_id: org.id, provider: :openrouter, secret: @secret},
                 actor: api_key
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.revoke_provider_key(key, actor: api_key)
    end

    test "an outsider cannot rotate or revoke another organization's key", %{org: org} do
      key = provider_key_fixture(org)
      stranger = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.rotate_provider_key(key, %{secret: @secret}, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.revoke_provider_key(key, actor: stranger)
    end

    test "a key registered in a team organization is visible to its members", %{owner: owner} do
      team = team_org_fixture(%{user: owner})
      key = provider_key_fixture(team, secret: @secret)

      assert {:ok, [found]} = Accounts.list_provider_keys(team.id, actor: owner)
      assert found.id == key.id

      outsider = user_fixture()
      assert {:ok, []} = Accounts.list_provider_keys(team.id, actor: outsider)
    end
  end

  describe "identity" do
    test "the same provider + label twice in one organization errors", %{org: org, owner: owner} do
      assert {:ok, _} = register(org, owner, :openrouter, "default")

      assert {:error, %Ash.Error.Invalid{}} = register(org, owner, :openrouter, "default")
    end

    test "different labels are fine, and other organizations are unaffected", %{
      org: org,
      owner: owner
    } do
      assert {:ok, _} = register(org, owner, :openrouter, "default")
      assert {:ok, _} = register(org, owner, :openrouter, "billing")

      other = team_org_fixture(%{user: owner})
      assert {:ok, _} = register(other, owner, :openrouter, "default")

      assert {:ok, keys} = Accounts.list_provider_keys(org.id, member_scope(owner))
      assert length(keys) == 2
    end
  end

  describe "active_provider_key/3" do
    test "returns the newest active key for the provider, nil after revoke", %{
      org: org,
      owner: owner
    } do
      old = provider_key_fixture(org, label: "old", secret: "sk-or-v1-aaaaaaaaaaaaaaaaOLD1")
      new = provider_key_fixture(org, label: "new", secret: "sk-or-v1-bbbbbbbbbbbbbbbbNEW2")

      assert {:ok, found} = Accounts.active_provider_key(org.id, :openrouter, member_scope(owner))
      assert found.id == new.id

      {:ok, _} = Accounts.revoke_provider_key(new, member_scope(owner))

      assert {:ok, found} = Accounts.active_provider_key(org.id, :openrouter, member_scope(owner))
      assert found.id == old.id

      {:ok, _} = Accounts.revoke_provider_key(old, member_scope(owner))

      assert {:ok, nil} = Accounts.active_provider_key(org.id, :openrouter, member_scope(owner))
    end

    test "does not cross organizations, and refuses a provider it cannot store", %{
      org: org,
      owner: owner
    } do
      _openrouter = provider_key_fixture(org)
      other = team_org_fixture(%{user: owner})
      _other_key = provider_key_fixture(other)

      # The argument constraint also uses `@providers` as-is: a provider that cannot be stored
      # cannot be looked up either.
      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.active_provider_key(org.id, :anthropic, member_scope(owner))

      assert {:ok, %{organization_id: organization_id}} =
               Accounts.active_provider_key(org.id, :openrouter, member_scope(owner))

      assert organization_id == org.id
    end

    test "one key serves every project in the organization", %{org: org, owner: owner} do
      key = provider_key_fixture(org, secret: @secret)
      one = project_fixture(%{user: owner, organization: org})
      two = project_fixture(%{user: owner, organization: org})

      for project <- [one, two] do
        assert {:ok, found} =
                 Accounts.active_provider_key(
                   project.organization_id,
                   :openrouter,
                   member_scope(owner)
                 )

        assert found.id == key.id
      end
    end

    test "load: [:secret] decrypts through the code interface", %{org: org, owner: owner} do
      _key = provider_key_fixture(org, secret: @secret)

      assert {:ok, %{secret: secret}} =
               Accounts.active_provider_key(
                 org.id,
                 :openrouter,
                 member_scope(owner) ++ [load: [:secret]]
               )

      assert secret == @secret
    end
  end

  describe "hint/1" do
    test "keeps a readable provider prefix and the last 4 characters" do
      assert ProviderKey.hint("sk-or-v1-0123456789abcdef4Xa2") == "sk-or-v1-••••4Xa2"
      assert ProviderKey.hint("sk-ant-api03-0123456789abcdefXYZW") == "sk-ant-api03-••••XYZW"
      assert ProviderKey.hint("sk-proj-0123456789abcdefQQQQ") == "sk-proj-••••QQQQ"
      assert ProviderKey.hint("gsk_0123456789abcdef") == "gsk_••••cdef"
      # Formats without a prefix (Google) are only masked
      assert ProviderKey.hint("AIzaSyA0123456789abcdef") == "••••cdef"
      # Short values hide even the last 4 characters
      assert ProviderKey.hint("short") == "••••"
      assert ProviderKey.hint("sk-abc") == "sk-••••"
      assert ProviderKey.hint("  ") == nil
      assert ProviderKey.hint(nil) == nil
    end
  end

  defp register(org, owner, provider, label) do
    Accounts.register_provider_key(
      %{
        organization_id: org.id,
        provider: provider,
        label: label,
        secret: "sk-or-v1-#{label}-0123456789abcdef"
      },
      actor: owner
    )
  end
end
