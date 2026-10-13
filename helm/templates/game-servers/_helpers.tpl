{{- define "gameServers.playitSidecar" -}}
- name: playit
  image: ghcr.io/playit-cloud/playit-agent:{{ .Values.gameServers.playit.version }}
  env:
    - name: SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: gameserver-playit
          key: secret-key
  resources:
    requests:
      cpu: "50m"
      memory: 64Mi
    limits:
      cpu: "250m"
      memory: 128Mi
{{- end -}}
