# LinkedIn: the gold image that could not update its own cluster

Source page:
[When a gold image cut from a RAC node cannot update the other node](monitoring/oem-gold-image-related-agent-check.md)

Format: single feed post, no carousel. The story is one idea and a carousel would pad
it.

---

## Feed post

**No URL anywhere in this text.** LinkedIn demotes posts carrying an external link, and
a link in the body is what produces the "Cannot display preview" warning. The link goes
in the first comment.

Character count: roughly 2,600 of the 3,000 limit.

---

Four days ago an Oracle Enterprise Manager agent refused to update. The reason it gave
named a target, not the cause.

NotUpdatable ERROR
Related agents are not updatable. Monitoring Target : +ASM_usatclust1,..

Two node Oracle RAC: oradbserv05 and oradbserv06. Back on EM 13.5 I built an agent gold
image using oradbserv05 as the source, because it was the first agent I built. That
image then provisioned the whole estate.

After upgrading the OMS to 24ai I went to refresh it. EM would not let me upgrade the
source agent alone: it is in a cluster, so oradbserv06 had to come too. I upgraded
both. Both succeeded.

Then oradbserv06 sat at the old image version, Pending, flagged as a drifter. Every
update attempt failed.

The console shows the drift. It does not show NotUpdatable. Two different things:

Drifter: the agent's software no longer matches the image version it is recorded on. A
label.

NotUpdatable: the job would not start. That reason only comes out of
emcli get_agent_update_status -op_name=... and you need the failed operation's name to
ask for it.

Read properly, the deadlock is complete:

1. Both nodes monitor +ASM_usatclust1, so EM treats the agents as related.
2. closureRelated defaults to true, so updating one auto-adds the other.
3. oradbserv05 is the image source, and an agent can never be updated from the image
cut from it.

Updating oradbserv06 requires oradbserv05 to be updatable. It never is. The check can
never pass.

Not transient. It survived a 13.5 to 24ai OMS upgrade and two image versions.

The fix is a parameter in the repository. EM_GI_MASTER_INFO holds closureRelated and
ignoreRelatedCheck. Oracle's 24ai guide names the first; I used the second. Set it,
update the one agent, set it straight back.

Guaranteed restore point before touching a SYSMAN table. Flag reverted the moment the
job reported Success. Restore point dropped after.

Three minutes forty four seconds, on an agent that had been unupdatable for four days.

The lesson is not the parameter. Do not cut an agent gold image from a clustered host.
If your source already sits on a RAC node, every other node of that cluster is
permanently blocked, and you find out a year later, mid upgrade.

Full write-up, every command and the failed output. Link in the comments.

Anyone hit this on a larger estate, where the source agent could not simply be moved?

#OracleEnterpriseManager #OracleDBA #OracleRAC #Oracle24ai #EMCLI #DBA

---

## First comment

Post as the first comment, so the post itself is not demoted for carrying an external
link.

The procedure, including the failed `get_agent_update_status` output, the
`EM_GI_MASTER_INFO` values before and after, and the restore point:

https://linkdapp.github.io/NestWise/monitoring/oem-gold-image-related-agent-check.html

The phase it came out of, patching six 24ai agents with no My Oracle Support account:
https://linkdapp.github.io/NestWise/monitoring/phase-7e-agent-patching.html

---

## Notes on this draft

| Choice | Reason |
|---|---|
| Opens with the error string | It is searchable. A DBA hitting `Related agents are not updatable` should land here |
| Drifter against `NotUpdatable` distinction kept | It is the part that cost four days, and it is the part the console hides |
| `closureRelated` named as the documented one | It is. `ignoreRelatedCheck` is not on that page, and claiming otherwise would be wrong |
| Restore point and flag revert both stated | A post that shows someone editing a SYSMAN table without either reads as reckless |
| Closes on the design lesson, not the parameter | The parameter helps the few who hit it. The lesson helps anyone about to build an image |
| Question aimed at larger estates | Invites the one group with experience this lab cannot produce |
| No backticks or code fences | LinkedIn renders them literally. The error string and command names are left as plain text |
| Under 2,700 characters | The limit is 3,000. The first draft was about 3,500 and was rejected |
