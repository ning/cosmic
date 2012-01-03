.. _`tomdz-jruby4r gem`: https://github.com/tomdz/jira4r
.. _`tomdz-soap4r gem`: https://github.com/tomdz/soap4r
.. _`soap4r`: https://github.com/felipec/soap4r
.. _`jira4r`: https://github.com/remi/jira4r

JIRA
====

The JIRA plugin can be used to create and update JIRA issues. For instance, you can use to create issues that track deployments, and add comments for each individual step of the deployment.

This plugin uses the `tomdz-jruby4r gem`_ which itself uses the `tomdz-soap4r gem`_. These two are forks of forks of the original `soap4r`_ and `jira4r`_ gems, which have been updated to work with (J)Ruby 1.9 and with each other::

    gem install tomdz-jira4r tomdz-soap4r

The JIRA plugin is configured as follows::

    jira:
      address: <Url of the JIRA server; default is http://localhost>
      <authentication configuration as explained above>

Similar to the IRC plugin, the JIRA plugin is typically used to update JIRA issues as deployments are performed. For instance, in order to automatically create a JIRA issue for a deployment and update it with comments documenting individual deployment steps, you could use something like::

    issue = with jira do
      issue = create_issue :project => 'DEPL', :type => 'New Feature', :summary => 'New deployment', :description => 'New deployment'
      connect :issue => issue, :to => :info
    end
    ...
    with jira do
      resolve :issue => issue, :comment => 'Deployment completed', :resolution => 'Fixed'
    end
